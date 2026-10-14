/**
 * Browser Run fallback (decisions D10): daily render budgets in D1 `render_budget` and the
 * `env.BROWSER.quickAction("content")` call. The binding returns a Response: 200 →
 * `{ success: true, result: "<html>", meta: { status, title, finalUrl?, headers? } }`, errors →
 * `{ success: false, errors: [{ message, code? }] }` with 4xx/5xx (workers-types `BrowserRun`).
 */
import { assertFetchable, BROWSER_UA } from "@sroka/extractor";
import { log } from "@sroka/shared";
import type { ParserEnv } from "./env.ts";

export const RENDER_TIMEOUT_MS = 30_000;
const DAY = 24 * 60 * 60 * 1000;

function intVar(v: string | undefined, dflt: number): number {
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 ? Math.floor(n) : dflt;
}

export function renderEnabled(env: ParserEnv): boolean {
  return env.BROWSER_RENDER_ENABLED === "true" && !!env.BROWSER;
}

/** Atomically takes one unit of a fixed-window counter if it is below `max`; false when exhausted. */
async function take(db: D1Database, key: string, max: number, expiresAt: number): Promise<boolean> {
  const row = await db
    .prepare(
      `INSERT INTO render_budget (key, count, expires_at) VALUES (?1, 1, ?3)
       ON CONFLICT(key) DO UPDATE SET count = count + 1 WHERE count < ?2 RETURNING count`,
    )
    .bind(key, max, expiresAt)
    .first<{ count: number }>();
  return !!row && row.count <= max;
}

/**
 * Takes one render from the per-user and the global daily budget (UTC day). False when either is exhausted or
 * D1 fails (fail closed: renders cost money). A user unit taken before the global check failed is given back.
 */
export async function takeRenderBudget(env: ParserEnv, userHash: string, now: number): Promise<boolean> {
  const day = Math.floor(now / DAY);
  const expiresAt = (day + 1) * DAY;
  const perUser = intVar(env.BROWSER_RENDER_DAILY_PER_USER, 30);
  const global = intVar(env.BROWSER_RENDER_DAILY_GLOBAL, 500);
  const userKey = `u:${userHash}:${day}`;
  try {
    if (!(await take(env.DB, userKey, perUser, expiresAt))) return false;
    if (await take(env.DB, `g:${day}`, global, expiresAt)) return true;
    await env.DB.prepare("UPDATE render_budget SET count = count - 1 WHERE key = ?1 AND count > 0").bind(userKey).run();
    return false;
  } catch (e) {
    log.warnException("render budget check failed", e, { event: "render_budget_failed" });
    return false;
  }
}

export interface RenderOptions {
  waitForSelector?: string;
  /** Rule `userAgent: "browser"` → explicit realistic UA (Browser Run's default is already a Chrome UA). */
  browserUa?: boolean;
  ownHosts: readonly string[];
}

export type RenderOutcome =
  | { ok: true; html: string; finalUrl: string; httpStatus: number | null; ms: number }
  | { ok: false; error: string; httpStatus: number | null; ms: number };

/** Renders `url` with Browser Run (30 s cap). Never throws. */
export async function renderPage(env: ParserEnv, url: string, o: RenderOptions): Promise<RenderOutcome> {
  const t0 = Date.now();
  const ms = () => Date.now() - t0;
  if (!env.BROWSER) return { ok: false, error: "render_unavailable", httpStatus: null, ms: 0 };
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const call = env.BROWSER.quickAction("content", {
      url,
      rejectResourceTypes: ["image", "media", "font"],
      gotoOptions: { waitUntil: "networkidle2", timeout: RENDER_TIMEOUT_MS - 5_000 },
      ...(o.waitForSelector ? { waitForSelector: { selector: o.waitForSelector, timeout: 10_000 } } : {}),
      ...(o.browserUa ? { userAgent: BROWSER_UA } : {}),
      bestAttempt: true,
    });
    const timeout = new Promise<never>((_, rej) => {
      timer = setTimeout(() => rej(new Error("render_timeout")), RENDER_TIMEOUT_MS);
    });
    const res = await Promise.race([call, timeout]);
    const body = (await res.json().catch(() => null)) as
      | { success?: boolean; result?: unknown; meta?: { status?: number; finalUrl?: string }; errors?: { message?: string }[] }
      | null;
    const httpStatus = typeof body?.meta?.status === "number" ? body.meta.status : null;
    if (!res.ok || !body?.success || typeof body.result !== "string") {
      log.warn("browser render failed", { event: "render_failed", status: res.status, message: body?.errors?.[0]?.message?.slice(0, 200) });
      return { ok: false, error: `render_http_${res.status}`, httpStatus, ms: ms() };
    }
    // The browser followed redirects itself: only use its final URL as the base if we'd have fetched it too.
    let finalUrl = url;
    if (body.meta?.finalUrl) {
      try {
        finalUrl = assertFetchable(body.meta.finalUrl, o.ownHosts).href;
      } catch {
        return { ok: false, error: "blocked_url", httpStatus, ms: ms() };
      }
    }
    return { ok: true, html: body.result, finalUrl, httpStatus, ms: ms() };
  } catch (e) {
    const timedOut = e instanceof Error && e.message === "render_timeout";
    log.warnException("browser render failed", e, { event: "render_failed" });
    return { ok: false, error: timedOut ? "render_timeout" : "render_error", httpStatus: null, ms: ms() };
  } finally {
    clearTimeout(timer);
  }
}
