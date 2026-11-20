/**
 * POST /api/auth/sign-out with a push-token backstop (docs/api.md §17, decisions D17). The phones' own
 * pre-sign-out `DELETE /v1/push-token` is best-effort and can be skipped; when the request carries a valid
 * `X-Sroka-Device`, the signed-out user's push row for that device is deleted here too, after Better Auth
 * revoked the session. The session is resolved first (the user's before hook runs ahead of the bearer
 * plugin, and the session is gone afterwards). Errors never change the sign-out response.
 */
import { DEVICE_HEADER, DeviceId, log, REST_DEVICE_ID } from "@sroka/shared";
import type { Context } from "hono";
import { createAuth } from "./auth.ts";
import type { AppEnv } from "./env.ts";

function signOutDevice(headers: Headers): string | null {
  const h = headers.get(DEVICE_HEADER);
  return h && h !== REST_DEVICE_ID && DeviceId.safeParse(h).success ? h : null;
}

export async function signOutHandler(c: Context<AppEnv>): Promise<Response> {
  const auth = createAuth(c.env, c.executionCtx);
  const deviceId = signOutDevice(c.req.raw.headers);
  let userId: string | null = null;
  if (deviceId) {
    try {
      const session = await auth.api.getSession({ headers: c.req.raw.headers, query: { disableRefresh: true } });
      userId = session?.user.id ?? null;
    } catch {
      log.warn("sign-out session lookup failed", { event: "push_signout_cleanup_failed", stage: "session" });
    }
  }
  const res = await auth.handler(c.req.raw);
  if (userId && deviceId && res.ok) {
    const p = c.env.LIBRARY.getByName(userId)
      .deletePushToken(deviceId)
      .catch(() => log.warn("sign-out push token cleanup failed", { event: "push_signout_cleanup_failed", stage: "delete" }));
    c.executionCtx.waitUntil(p);
  }
  return res;
}
