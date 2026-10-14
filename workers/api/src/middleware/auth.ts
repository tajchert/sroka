import { createMiddleware } from "hono/factory";
import { cors } from "hono/cors";
import type { AppEnv } from "../env.ts";
import { createAuth, devOrigins } from "../auth.ts";

/** CORS for /api/* and /v1/* (api.md §2). */
export const corsMiddleware = cors({
  origin: (origin, c) => {
    if (!origin) return null;
    const env = c.env as AppEnv["Bindings"];
    if (origin === env.APP_ORIGIN || devOrigins(env).includes(origin)) return origin;
    if (origin.startsWith("chrome-extension://") || origin.startsWith("moz-extension://")) return origin;
    return null;
  },
  allowMethods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
  allowHeaders: ["Content-Type", "Authorization", "X-Sroka-Device", "X-Turnstile-Token"],
  exposeHeaders: ["set-auth-token", "Retry-After", "X-Retry-After", "Content-Disposition"],
  credentials: false,
  maxAge: 600,
});

/**
 * /v1 auth: Better Auth session (cookie or bearer) → c.var.userId, else 401. When Better Auth refreshes the
 * session (updateAge passed), its Set-Cookie is forwarded so the browser cookie's Max-Age moves along with
 * the server-side expiry (the web app never calls /api/auth/get-session itself).
 */
export const requireAuth = createMiddleware<AppEnv>(async (c, next) => {
  const { headers, response: session } = await createAuth(c.env, c.executionCtx).api.getSession({
    headers: c.req.raw.headers,
    returnHeaders: true,
  });
  if (!session) return c.json({ error: "unauthorized" }, 401);
  c.set("userId", session.user.id);
  await next();
  const cookies = headers?.getSetCookie?.() ?? [];
  if (cookies.length === 0) return;
  try {
    for (const v of cookies) c.res.headers.append("set-cookie", v);
  } catch {
    // Immutable response headers (e.g. a proxied R2 body): rebuild the response.
    const res = new Response(c.res.body, c.res);
    for (const v of cookies) res.headers.append("set-cookie", v);
    c.res = res;
  }
});
