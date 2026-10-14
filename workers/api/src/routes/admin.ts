import { Hono } from "hono";
import { createMiddleware } from "hono/factory";
import { eq } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import {
  AdminAttemptsQuery,
  AdminSummaryQuery,
  SITE_RULE_KEY_PREFIX,
  SiteRuleSchema,
  log,
  ruleHost,
  siteRuleKey,
  toApiError,
  type AdminAttempt,
  type AdminAttemptsResponse,
  type AdminDomainSummary,
  type AdminSiteRuleEntry,
  type AdminSiteRulesResponse,
  type AdminSummaryResponse,
  type SiteRule,
} from "@sroka/shared";
import type { AppEnv, Env } from "../env.ts";
import * as authSchema from "../db/auth-schema.ts";

/** True when `email` is listed (case-insensitive, comma-separated) in env `ADMIN_EMAILS`. */
export function isAdminEmail(env: Pick<Env, "ADMIN_EMAILS">, email: string | null | undefined): boolean {
  if (!email || !env.ADMIN_EMAILS) return false;
  const e = email.trim().toLowerCase();
  return e !== "" && env.ADMIN_EMAILS.split(",").some((x) => x.trim().toLowerCase() === e);
}

/** Non-admins (and everyone when ADMIN_EMAILS is unset) get 404, so the surface is not discoverable. */
const requireAdmin = createMiddleware<AppEnv>(async (c, next) => {
  const db = drizzle(c.env.DB, { schema: authSchema });
  const u = (await db.select({ email: authSchema.user.email }).from(authSchema.user).where(eq(authSchema.user.id, c.var.userId)).limit(1))[0];
  if (!isAdminEmail(c.env, u?.email)) return c.json({ error: "not_found" }, 404);
  await next();
});

export const adminRoutes = new Hono<AppEnv>();
adminRoutes.use("*", requireAdmin);

const DAY_MS = 86_400_000;
const MAX_DOMAINS = 500;

const num = (v: unknown): number => (typeof v === "number" ? v : Number(v ?? 0));

// ---------- parse analytics ----------

type CountRow = Record<"total" | "ok" | "partial" | "failed" | "render_tried" | "render_ok" | "render_budget", number | null>;
const COUNTS = `COUNT(*) AS total,
    SUM(CASE WHEN status = 'ok' THEN 1 ELSE 0 END) AS ok,
    SUM(CASE WHEN status = 'partial' THEN 1 ELSE 0 END) AS partial,
    SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed,
    SUM(CASE WHEN fallback_outcome IN ('ok','partial','failed') THEN 1 ELSE 0 END) AS render_tried,
    SUM(CASE WHEN fallback_outcome = 'ok' THEN 1 ELSE 0 END) AS render_ok,
    SUM(CASE WHEN fallback_outcome = 'budget' THEN 1 ELSE 0 END) AS render_budget`;
const counts = (r: CountRow) => ({
  total: num(r.total),
  ok: num(r.ok),
  partial: num(r.partial),
  failed: num(r.failed),
  renderTried: num(r.render_tried),
  renderOk: num(r.render_ok),
  renderBudgetBlocked: num(r.render_budget),
});

adminRoutes.get("/parse/summary", async (c) => {
  const q = AdminSummaryQuery.safeParse({ days: c.req.query("days") });
  if (!q.success) return c.json(toApiError(q.error), 400);
  const days = q.data.days;
  const since = Date.now() - days * DAY_MS;

  const [totalsRes, domainsRes, errorsRes, dailyRes] = await c.env.DB.batch([
    c.env.DB.prepare(`SELECT ${COUNTS} FROM parse_attempts WHERE created_at >= ?`).bind(since),
    c.env.DB.prepare(
      `SELECT domain, ${COUNTS}, MAX(created_at) AS last_at FROM parse_attempts WHERE created_at >= ?
       GROUP BY domain ORDER BY failed DESC, total DESC LIMIT ?`,
    ).bind(since, MAX_DOMAINS),
    c.env.DB.prepare(
      `SELECT domain, error_code, n FROM (
         SELECT domain, error_code, COUNT(*) AS n,
                ROW_NUMBER() OVER (PARTITION BY domain ORDER BY COUNT(*) DESC, error_code) AS rn
         FROM parse_attempts WHERE created_at >= ? AND error_code IS NOT NULL GROUP BY domain, error_code
       ) WHERE rn <= 3 ORDER BY domain, rn`,
    ).bind(since),
    c.env.DB.prepare(
      `SELECT strftime('%Y-%m-%d', created_at / 1000, 'unixepoch') AS day, COUNT(*) AS total,
        SUM(CASE WHEN status = 'ok' THEN 1 ELSE 0 END) AS ok,
        SUM(CASE WHEN status = 'partial' THEN 1 ELSE 0 END) AS partial,
        SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed
       FROM parse_attempts WHERE created_at >= ? GROUP BY day ORDER BY day`,
    ).bind(since),
  ]);

  const topErrors = new Map<string, { code: string; count: number }[]>();
  for (const r of (errorsRes!.results ?? []) as { domain: string; error_code: string; n: number }[]) {
    const list = topErrors.get(r.domain) ?? [];
    list.push({ code: r.error_code, count: num(r.n) });
    topErrors.set(r.domain, list);
  }
  const domains: AdminDomainSummary[] = ((domainsRes!.results ?? []) as (CountRow & { domain: string; last_at: number })[]).map((r) => ({
    domain: r.domain,
    ...counts(r),
    lastAttemptAt: num(r.last_at),
    topErrors: topErrors.get(r.domain) ?? [],
  }));
  const body: AdminSummaryResponse = {
    days,
    since,
    totals: counts(((totalsRes!.results ?? [])[0] ?? {}) as CountRow),
    daily: ((dailyRes!.results ?? []) as { day: string; total: number; ok: number; partial: number; failed: number }[]).map((r) => ({
      day: r.day,
      total: num(r.total),
      ok: num(r.ok),
      partial: num(r.partial),
      failed: num(r.failed),
    })),
    domains,
  };
  return c.json(body);
});

interface AttemptRow {
  id: string | number;
  created_at: number;
  domain: string;
  url: string | null;
  item_id: string | null;
  status: string;
  error_code: string | null;
  error_detail: string | null;
  method: string;
  fallback_outcome: string;
  http_status: number | null;
  text_chars: number | null;
  word_count: number | null;
  images: number | null;
  duration_ms: number | null;
  render_ms: number | null;
  attempt: number | null;
  parser_version: string | null;
  rule_applied: number | null;
}

function encodeCursor(createdAt: number, id: string): string {
  return btoa(JSON.stringify([createdAt, id])).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function decodeCursor(s: string): [number, string] | null {
  try {
    const v = JSON.parse(atob(s.replace(/-/g, "+").replace(/_/g, "/"))) as unknown;
    if (Array.isArray(v) && v.length === 2 && typeof v[0] === "number" && typeof v[1] === "string") return [v[0], v[1]];
  } catch {
    /* fallthrough */
  }
  return null;
}

adminRoutes.get("/parse/attempts", async (c) => {
  const q = AdminAttemptsQuery.safeParse(Object.fromEntries(new URL(c.req.url).searchParams));
  if (!q.success) return c.json(toApiError(q.error), 400);
  const { domain, status, method, fallback, cursor, limit } = q.data;
  const where: string[] = [];
  const args: (string | number)[] = [];
  if (domain) {
    where.push("domain = ?");
    args.push(domain.toLowerCase());
  }
  if (status) {
    where.push("status = ?");
    args.push(status);
  }
  if (method) {
    where.push("method = ?");
    args.push(method);
  }
  if (fallback) {
    where.push("fallback_outcome = ?");
    args.push(fallback);
  }
  if (cursor) {
    const cur = decodeCursor(cursor);
    if (!cur) return c.json({ error: "invalid_request", message: "invalid_cursor" }, 400);
    where.push("(created_at < ? OR (created_at = ? AND id < ?))");
    args.push(cur[0], cur[0], cur[1]);
  }
  const sql = `SELECT id, created_at, domain, url, item_id, status, error_code, error_detail, method, fallback_outcome,
      http_status, text_chars, word_count, images, duration_ms, render_ms, attempt, parser_version, rule_applied
    FROM parse_attempts ${where.length ? "WHERE " + where.join(" AND ") : ""}
    ORDER BY created_at DESC, id DESC LIMIT ?`;
  const rows = ((await c.env.DB.prepare(sql).bind(...args, limit + 1).all<AttemptRow>()).results ?? []) as AttemptRow[];
  const page = rows.slice(0, limit);
  const attempts: AdminAttempt[] = page.map((r) => ({
    id: String(r.id),
    createdAt: num(r.created_at),
    domain: r.domain,
    url: r.url,
    itemId: r.item_id,
    status: r.status,
    errorCode: r.error_code,
    errorDetail: r.error_detail,
    method: r.method,
    fallbackOutcome: r.fallback_outcome,
    httpStatus: r.http_status,
    textChars: r.text_chars,
    wordCount: r.word_count,
    images: r.images,
    durationMs: r.duration_ms,
    renderMs: r.render_ms,
    attempt: r.attempt,
    parserVersion: r.parser_version,
    ruleApplied: !!r.rule_applied,
  }));
  const last = page[page.length - 1];
  const body: AdminAttemptsResponse = {
    attempts,
    nextCursor: rows.length > limit && last ? encodeCursor(num(last.created_at), String(last.id)) : null,
  };
  return c.json(body);
});

// ---------- site rules (KV CONFIG, D10) ----------

async function readRule(env: Env, key: string): Promise<SiteRule | null> {
  const raw = await env.CONFIG.get(key, "json");
  if (raw === null) return null;
  const p = SiteRuleSchema.safeParse(raw);
  if (!p.success) {
    log.warn("invalid stored site rule", { event: "site_rule_invalid", key });
    return null;
  }
  return p.data;
}

adminRoutes.get("/site-rules", async (c) => {
  const keys: string[] = [];
  let cursor: string | undefined;
  do {
    const page = await c.env.CONFIG.list({ prefix: SITE_RULE_KEY_PREFIX, cursor });
    for (const k of page.keys) keys.push(k.name);
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor && keys.length < 1000);
  const entries = await Promise.all(
    keys.map(async (k): Promise<AdminSiteRuleEntry | null> => {
      const rule = await readRule(c.env, k);
      return rule ? { host: k.slice(SITE_RULE_KEY_PREFIX.length), rule } : null;
    }),
  );
  const body: AdminSiteRulesResponse = {
    rules: entries.filter((e): e is AdminSiteRuleEntry => e !== null).sort((a, b) => a.host.localeCompare(b.host)),
  };
  return c.json(body);
});

const HOST_RE = /^(?=.{1,253}$)[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/;
function paramHost(raw: string): string | null {
  let h: string;
  try {
    h = ruleHost(decodeURIComponent(raw));
  } catch {
    return null;
  }
  return HOST_RE.test(h) ? h : null;
}

adminRoutes.get("/site-rules/:host", async (c) => {
  const host = paramHost(c.req.param("host"));
  if (!host) return c.json({ error: "invalid_request", message: "invalid_host" }, 400);
  const rule = await readRule(c.env, siteRuleKey(host));
  if (!rule) return c.json({ error: "not_found" }, 404);
  return c.json({ host, rule });
});

adminRoutes.put("/site-rules/:host", async (c) => {
  const host = paramHost(c.req.param("host"));
  if (!host) return c.json({ error: "invalid_request", message: "invalid_host" }, 400);
  let raw: unknown;
  try {
    raw = await c.req.json();
  } catch {
    return c.json({ error: "invalid_request", message: "invalid_json" }, 400);
  }
  const p = SiteRuleSchema.safeParse(raw);
  if (!p.success) return c.json(toApiError(p.error), 400);
  const rule: SiteRule = { ...p.data, updatedAt: Date.now() };
  await c.env.CONFIG.put(siteRuleKey(host), JSON.stringify(rule));
  log.info("site rule saved", { event: "site_rule_put", host });
  return c.json({ host, rule });
});

adminRoutes.delete("/site-rules/:host", async (c) => {
  const host = paramHost(c.req.param("host"));
  if (!host) return c.json({ error: "invalid_request", message: "invalid_host" }, 400);
  await c.env.CONFIG.delete(siteRuleKey(host));
  log.info("site rule deleted", { event: "site_rule_delete", host });
  return c.body(null, 204);
});
