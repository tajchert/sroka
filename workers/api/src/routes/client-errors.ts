/** POST /v1/client-errors — docs/api.md §12. Public, lightly rate-limited, log-only. */
import { ClientErrorRequest, log, toApiError, writeMetric } from "@sroka/shared";
import { Hono } from "hono";
import type { AppEnv } from "../env.ts";

export const clientErrorRoutes = new Hono<AppEnv>();

const MAX_BODY = 16 * 1024;
const LIMIT = 10;
const WINDOW_MS = 60_000;
/** Best-effort per-isolate limiter (abuse damper, not a security boundary). */
const hits = new Map<string, { n: number; reset: number }>();

export function resetClientErrorLimiter(): void {
  hits.clear();
}

function limited(key: string, now: number): number {
  if (hits.size > 5000) hits.clear();
  const h = hits.get(key);
  if (!h || h.reset <= now) {
    hits.set(key, { n: 1, reset: now + WINDOW_MS });
    return 0;
  }
  h.n++;
  return h.n > LIMIT ? Math.ceil((h.reset - now) / 1000) : 0;
}

clientErrorRoutes.post("/client-errors", async (c) => {
  const retry = limited(c.req.header("cf-connecting-ip") ?? "local", Date.now());
  if (retry) return c.json({ error: "rate_limited" }, 429, { "Retry-After": String(retry) });
  const len = Number(c.req.header("content-length") ?? "0");
  if (len > MAX_BODY) return c.json({ error: "payload_too_large" }, 413);
  const text = await c.req.text();
  if (text.length > MAX_BODY) return c.json({ error: "payload_too_large" }, 413);
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    return c.json({ error: "invalid_request", message: "invalid_json" }, 400);
  }
  const parsed = ClientErrorRequest.safeParse(body);
  if (!parsed.success) return c.json(toApiError(parsed.error), 400);
  const e = parsed.data;
  log.error("client error", {
    event: "client_error",
    requestId: c.var.requestId,
    clientMessage: e.message,
    clientStack: e.stack,
    clientPath: e.url,
    userAgent: e.userAgent,
    release: e.release,
  });
  writeMetric(c.env.METRICS, { event: "client_error", blobs: [e.url ?? "", e.release ?? ""] });
  return c.body(null, 204);
});
