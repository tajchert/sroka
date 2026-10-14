import { Hono } from "hono";
import { eq, like } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { DeleteAccountRequest, toApiError, type MeResponse } from "@sroka/shared";
import type { AppEnv, Env } from "../env.ts";
import * as authSchema from "../db/auth-schema.ts";
import { jobs } from "../db/schema.ts";

export const accountRoutes = new Hono<AppEnv>();

type Stats = MeResponse["stats"];
/** Stats helper on the LibraryDO (internal to workers/api, api.md §15); tolerate a DO without it. */
type LibraryStub = { stats?: () => Promise<Stats>; destroy?: () => Promise<unknown> };

accountRoutes.get("/me", async (c) => {
  const userId = c.var.userId;
  const db = drizzle(c.env.DB, { schema: authSchema });
  const u = (await db.select().from(authSchema.user).where(eq(authSchema.user.id, userId)).limit(1))[0];
  if (!u) return c.json({ error: "unauthorized" }, 401);
  let stats: Stats = { unread: 0, archived: 0, favorites: 0, tags: 0 };
  try {
    const stub = c.env.LIBRARY.getByName(userId) as unknown as LibraryStub;
    stats = await stub.stats!();
  } catch (e) {
    if (!isMissingRpc(e)) console.error("[sroka] stats failed", e);
  }
  const body: MeResponse = {
    user: {
      id: u.id,
      email: u.email,
      name: u.name ?? null,
      emailVerified: u.emailVerified,
      createdAt: u.createdAt.getTime(),
    },
    stats,
  };
  return c.json(body);
});

/** True while LibraryDO lacks the method (placeholder DO before merge). */
function isMissingRpc(e: unknown): boolean {
  return e instanceof Error && /does not implement|not a function/.test(e.message);
}

/** Delete all R2 objects under a prefix (paged). */
export async function deletePrefix(bucket: R2Bucket, prefix: string): Promise<void> {
  let cursor: string | undefined;
  do {
    const page = await bucket.list({ prefix, cursor, limit: 1000 });
    if (page.objects.length) await bucket.delete(page.objects.map((o) => o.key));
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
}

export async function deleteAccountData(env: Env, userId: string, email: string): Promise<void> {
  const db = drizzle(env.DB, { schema: authSchema });
  // Library first (may fail → user can retry while still signed in).
  const stub = env.LIBRARY.getByName(userId) as unknown as LibraryStub;
  try {
    await stub.destroy!();
  } catch (e) {
    if (!isMissingRpc(e)) throw e;
  }
  await db.delete(jobs).where(eq(jobs.userId, userId));
  await db.delete(authSchema.session).where(eq(authSchema.session.userId, userId));
  await db.delete(authSchema.account).where(eq(authSchema.account.userId, userId));
  await db.delete(authSchema.verification).where(like(authSchema.verification.identifier, `%${email}%`));
  await db.delete(authSchema.user).where(eq(authSchema.user.id, userId));
}

accountRoutes.delete("/account", async (c) => {
  const parsed = DeleteAccountRequest.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json(toApiError(parsed.error), 400);
  const userId = c.var.userId;
  const db = drizzle(c.env.DB, { schema: authSchema });
  const u = (await db.select({ email: authSchema.user.email }).from(authSchema.user).where(eq(authSchema.user.id, userId)).limit(1))[0];
  if (!u) return c.json({ error: "unauthorized" }, 401);
  await deleteAccountData(c.env, userId, u.email);
  c.executionCtx.waitUntil(
    Promise.all(
      [`private/${userId}/`, `raw/${userId}/`, `uploads/${userId}/`].map((p) => deletePrefix(c.env.CONTENT, p)),
    ).catch((e) => console.error("[sroka] R2 wipe failed", e)),
  );
  return c.json({ deleted: true as const });
});
