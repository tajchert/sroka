import { Hono } from "hono";
import { eq, inArray } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { DeleteAccountRequest, hashId, log, toApiError, type MeResponse } from "@sroka/shared";
import type { AppEnv, Env } from "../env.ts";
import * as authSchema from "../db/auth-schema.ts";
import { jobs } from "../db/schema.ts";
import { deletePrefix } from "../r2.ts";
import { isAdminEmail } from "./admin.ts";
import { clientKind } from "../clients.ts";

export { deletePrefix };

export const accountRoutes = new Hono<AppEnv>();

type Stats = MeResponse["stats"];
/** Stats helper on the LibraryDO (internal to workers/api, api.md §15); tolerate a DO without it. */
type Clients = NonNullable<MeResponse["clients"]>;
type LibraryStub = { stats?: () => Promise<Stats>; clients?: () => Promise<Clients>; destroy?: () => Promise<unknown> };

accountRoutes.get("/me", async (c) => {
  const userId = c.var.userId;
  const db = drizzle(c.env.DB, { schema: authSchema });
  const u = (await db.select().from(authSchema.user).where(eq(authSchema.user.id, userId)).limit(1))[0];
  if (!u) return c.json({ error: "unauthorized" }, 401);
  let stats: Stats = { unread: 0, archived: 0, favorites: 0, tags: 0 };
  let clients: Clients = { extension: false, android: false };
  const stub = c.env.LIBRARY.getByName(userId) as unknown as LibraryStub;
  const [st, cl] = await Promise.allSettled([stub.stats!(), stub.clients!()]);
  if (st.status === "fulfilled") stats = st.value;
  else if (!isMissingRpc(st.reason)) log.exception("stats failed", st.reason, { event: "stats_failed" });
  if (cl.status === "fulfilled") clients = cl.value;
  else if (!isMissingRpc(cl.reason)) log.warnException("clients failed", cl.reason, { event: "clients_failed" });
  // The flag for this very request may still be in flight (waitUntil in requireAuth).
  const current = clientKind(c.req.raw.headers);
  if (current) clients = { ...clients, [current]: true };
  const body: MeResponse = {
    user: {
      id: u.id,
      email: u.email,
      name: u.name ?? null,
      emailVerified: u.emailVerified,
      createdAt: u.createdAt.getTime(),
    },
    stats,
    isAdmin: isAdminEmail(c.env, u.email),
    clients,
  };
  return c.json(body);
});

/** True while LibraryDO lacks the method (placeholder DO before merge). */
function isMissingRpc(e: unknown): boolean {
  return e instanceof Error && /does not implement|not a function/.test(e.message);
}

export async function deleteAccountData(
  env: Env,
  userId: string,
  email: string,
  afterLibraryWipe?: () => void,
): Promise<void> {
  const userHash = await hashId(userId);
  log.info("account deletion started", { event: "account_delete", step: "start", userHash });
  const db = drizzle(env.DB, { schema: authSchema });
  // Stop running imports first so they can't recreate library data after the wipe (workflow id = job id).
  const running = await env.DB.prepare("SELECT id FROM jobs WHERE user_id = ? AND kind = 'import' AND status IN ('queued','running')")
    .bind(userId)
    .all<{ id: string }>();
  await Promise.all(
    (running.results ?? []).map(async (r) => {
      try {
        await env.IMPORT_WORKFLOW?.get(r.id).then((w) => w.terminate());
      } catch {
        /* already finished / not found */
      }
    }),
  );
  // Library first (may fail → user can retry while still signed in).
  const stub = env.LIBRARY.getByName(userId) as unknown as LibraryStub;
  try {
    await stub.destroy!();
  } catch (e) {
    if (!isMissingRpc(e)) throw e;
  }
  log.info("account deletion: library wiped", { event: "account_delete", step: "library_destroyed", userHash });
  afterLibraryWipe?.(); // start the R2 wipe independently of the D1 step
  // One atomic batch; session last so a failure leaves the user signed in and able to retry.
  await db.batch([
    db.delete(jobs).where(eq(jobs.userId, userId)),
    db.delete(authSchema.account).where(eq(authSchema.account.userId, userId)),
    db.delete(authSchema.verification).where(
      inArray(
        authSchema.verification.identifier,
        ["sign-in-otp-", "email-verification-otp-", "forget-password-otp-"].map((p) => p + email),
      ),
    ),
    db.delete(authSchema.user).where(eq(authSchema.user.id, userId)),
    db.delete(authSchema.session).where(eq(authSchema.session.userId, userId)),
  ]);
  log.info("account deletion: D1 rows deleted", { event: "account_delete", step: "d1_deleted", userHash });
}

accountRoutes.delete("/account", async (c) => {
  const parsed = DeleteAccountRequest.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json(toApiError(parsed.error), 400);
  const userId = c.var.userId;
  const db = drizzle(c.env.DB, { schema: authSchema });
  const u = (await db.select({ email: authSchema.user.email }).from(authSchema.user).where(eq(authSchema.user.id, userId)).limit(1))[0];
  if (!u) return c.json({ error: "unauthorized" }, 401);
  await deleteAccountData(c.env, userId, u.email, () =>
    c.executionCtx.waitUntil(
      Promise.all(
        [`private/${userId}/`, `raw/${userId}/`, `uploads/${userId}/`].map((p) => deletePrefix(c.env.CONTENT, p)),
      ).catch((e) => log.exception("account R2 wipe failed", e, { event: "account_r2_wipe_failed" })),
    ),
  );
  return c.json({ deleted: true as const });
});
