import { createMiddleware } from "hono/factory";
import type { ErrorHandler } from "hono";
import { HTTPException } from "hono/http-exception";
import { errorFields, hashId, log, writeMetric } from "@sroka/shared";
import type { AppEnv } from "../env.ts";

/** Requests slower than this are logged at warn even on quiet paths. */
export const SLOW_MS = 1500;

/** Request id for support: the cf-ray (`<id>-<colo>`), else a random uuid (local dev, tests). */
export function requestIdOf(req: Request): string {
  return req.headers.get("cf-ray") ?? crypto.randomUUID();
}

function colo(req: Request): string | undefined {
  return (req as { cf?: { colo?: string } }).cf?.colo;
}

/** Quiet = static assets, SPA, health, content host: logged only on errors / slow. */
function isQuiet(path: string, host: string, contentHost: string): boolean {
  if (host === contentHost) return true;
  if (path === "/v1/health") return true;
  return !(path.startsWith("/v1/") || path.startsWith("/api/"));
}

/** Route pattern for logs (never the raw path with ids): last non-wildcard matched route, else "(unmatched)". */
function routePattern(c: { req: { matchedRoutes: { path: string }[] } }): string {
  const m = c.req.matchedRoutes.filter((r) => !r.path.endsWith("*"));
  return m.length ? m[m.length - 1]!.path : "(unmatched)";
}

/** Request-level logging: sets `requestId` + `x-request-id`, logs one `http_request` line per request. */
export const requestLogger = createMiddleware<AppEnv>(async (c, next) => {
  const start = Date.now();
  const requestId = requestIdOf(c.req.raw);
  c.set("requestId", requestId);
  await next();
  try {
    c.res.headers.set("x-request-id", requestId);
  } catch {
    /* immutable headers (proxied response) */
  }
  const url = new URL(c.req.url);
  const durationMs = Date.now() - start;
  const status = c.res.status;
  let contentHost = "";
  try {
    contentHost = new URL(c.env.CONTENT_ORIGIN).host;
  } catch {
    /* ignore */
  }
  const quiet = isQuiet(url.pathname, url.host, contentHost);
  const slow = durationMs >= SLOW_MS;
  if (quiet && status < 500 && !slow) return;
  const userId = c.var.userId;
  log[status >= 500 ? "error" : slow || status === 429 ? "warn" : "info"]("request", {
    event: "http_request",
    requestId,
    method: c.req.method,
    route: routePattern(c),
    host: url.host,
    status,
    durationMs,
    slow,
    colo: colo(c.req.raw),
    userHash: userId ? await hashId(userId) : undefined,
  });
});

/** Hono onError: log with stack + context, answer `{error:"internal", requestId}`. */
export const onError: ErrorHandler<AppEnv> = async (err, c) => {
  if (err instanceof HTTPException) return err.getResponse();
  const requestId = c.var.requestId ?? requestIdOf(c.req.raw);
  const route = routePattern(c);
  const userId = c.var.userId;
  log.error("unhandled error", {
    event: "unhandled_error",
    requestId,
    method: c.req.method,
    route,
    path: new URL(c.req.url).pathname.replace(/[0-9a-f]{8}-[0-9a-f-]{27}/gi, ":id"),
    colo: colo(c.req.raw),
    userHash: userId ? await hashId(userId) : undefined,
    ...errorFields(err),
  });
  writeMetric(c.env.METRICS, { event: "error", blobs: [route, err instanceof Error ? err.name : "NonError"], index: route });
  return c.json({ error: "internal", requestId }, 500, { "x-request-id": requestId });
};
