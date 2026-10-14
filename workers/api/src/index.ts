import { Hono } from "hono";
import type { AppEnv } from "./env.ts";
import { createAuth } from "./auth.ts";
import { serveAsset } from "./assets.ts";
import { corsMiddleware, requireAuth } from "./middleware/auth.ts";
import { handleContent } from "./routes/content.ts";
import { accountRoutes } from "./routes/account.ts";
import { configRoutes } from "./routes/config.ts";
import { itemsRoutes } from "./routes/items.ts";
import { tagsRoutes } from "./routes/tags.ts";
import { syncRoutes } from "./routes/sync.ts";
import { importsRoutes } from "./routes/imports.ts";
import { clientErrorRoutes } from "./routes/client-errors.ts";
import { exportsRoutes } from "./routes/exports.ts";
import { onError, requestLogger } from "./middleware/logging.ts";

export { LibraryDO } from "./library-do.ts";
export { ImportWorkflow } from "./import/workflow.ts";

const app = new Hono<AppEnv>();

app.use("*", requestLogger);

// Host branching (api.md §2): the content host serves signed content only.
app.use("*", async (c, next) => {
  if (new URL(c.req.url).host === new URL(c.env.CONTENT_ORIGIN).host) return handleContent(c.req.raw, c.env);
  await next();
});

app.use("/api/*", corsMiddleware);
app.use("/v1/*", corsMiddleware);

// Better Auth (cookie + bearer).
app.on(["GET", "POST"], "/api/auth/*", (c) => createAuth(c.env, c.executionCtx).handler(c.req.raw));

// Public /v1 endpoints (registered before the auth middleware).
app.get("/v1/health", (c) => c.json({ ok: true }));
app.route("/v1", configRoutes);
app.route("/v1", clientErrorRoutes);

// Authenticated /v1.
app.use("/v1/*", requireAuth);
app.route("/v1", accountRoutes);
app.route("/v1/items", itemsRoutes);
app.route("/v1/tags", tagsRoutes);
app.route("/v1/sync", syncRoutes);
app.route("/v1/imports", importsRoutes);
app.route("/v1/exports", exportsRoutes);

app.onError(onError);

// Everything else: /v1 and /api unknown → JSON 404; otherwise static assets (landing, /app/* with SPA fallback).
app.notFound((c) => {
  const p = new URL(c.req.url).pathname;
  if (p.startsWith("/v1/") || p.startsWith("/api/")) return c.json({ error: "not_found" }, 404);
  return serveAsset(c.req.raw, c.env);
});
app.all("/app/*", (c) => serveAsset(c.req.raw, c.env));
app.all("/app", (c) => serveAsset(c.req.raw, c.env));

export default app;
