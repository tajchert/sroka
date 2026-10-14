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
  allowMethods: ["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
  allowHeaders: ["Content-Type", "Authorization", "X-Sroka-Device"],
  exposeHeaders: ["set-auth-token", "Retry-After", "X-Retry-After", "Content-Disposition"],
  credentials: false,
  maxAge: 600,
});

/** /v1 auth: Better Auth session (cookie or bearer) → c.var.userId, else 401. */
export const requireAuth = createMiddleware<AppEnv>(async (c, next) => {
  const session = await createAuth(c.env, c.executionCtx).api.getSession({ headers: c.req.raw.headers });
  if (!session) return c.json({ error: "unauthorized" }, 401);
  c.set("userId", session.user.id);
  await next();
});
