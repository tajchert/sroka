import { beforeAll, describe, expect, it } from "vitest";
import { call, migrate, signIn, testEnv } from "./helpers.ts";
import type { Env } from "../../src/env.ts";

const ADMIN = "Admin@Example.com";
const env: Env = { ...testEnv, ADMIN_EMAILS: " other@example.com , admin@example.com " };

let admin: { token: string };
let user: { token: string };

const auth = (t: { token: string }, extra: RequestInit = {}): RequestInit => ({
  ...extra,
  headers: { authorization: `Bearer ${t.token}`, "content-type": "application/json", ...(extra.headers ?? {}) },
});
const get = (t: { token: string }, path: string) => call(`/v1/admin${path}`, auth(t), undefined, env);

const NOW = Date.now();
const HOUR = 3_600_000;
interface Row {
  id: string;
  at: number;
  domain: string;
  status: string;
  err?: string | null;
  method?: string;
  fb?: string;
  url?: string | null;
}
const rows: Row[] = [
  { id: "a1", at: NOW - 1 * HOUR, domain: "a.com", status: "ok" },
  { id: "a2", at: NOW - 2 * HOUR, domain: "a.com", status: "failed", err: "blocked", fb: "ok", method: "render" },
  { id: "a3", at: NOW - 3 * HOUR, domain: "a.com", status: "failed", err: "blocked", fb: "budget" },
  { id: "a4", at: NOW - 3 * HOUR, domain: "a.com", status: "partial", err: "too_short", fb: "failed" },
  { id: "b1", at: NOW - 4 * HOUR, domain: "b.org", status: "ok", url: null, method: "capture" },
  { id: "b2", at: NOW - 5 * 24 * 3600_000, domain: "b.org", status: "failed", err: "timeout" },
  { id: "c1", at: NOW - 40 * 24 * 3600_000, domain: "old.net", status: "failed", err: "x" },
];

beforeAll(async () => {
  await migrate();
  // Table is created by a migration on the parser branch; create it here when the migration is absent.
  await testEnv.DB.prepare(
    `CREATE TABLE IF NOT EXISTS parse_attempts (id TEXT PRIMARY KEY NOT NULL, created_at INTEGER NOT NULL, user_hash TEXT, item_id TEXT,
      domain TEXT NOT NULL, url TEXT, status TEXT NOT NULL, error_code TEXT, error_detail TEXT, method TEXT NOT NULL,
      fallback_outcome TEXT NOT NULL, http_status INTEGER, text_chars INTEGER, word_count INTEGER, images INTEGER,
      duration_ms INTEGER, render_ms INTEGER, attempt INTEGER, parser_version TEXT, rule_applied INTEGER NOT NULL DEFAULT 0)`,
  ).run();
  await testEnv.DB.prepare("DELETE FROM parse_attempts").run();
  for (const r of rows) {
    await testEnv.DB.prepare(
      `INSERT INTO parse_attempts (id, created_at, domain, url, status, error_code, method, fallback_outcome) VALUES (?,?,?,?,?,?,?,?)`,
    )
      .bind(r.id, r.at, r.domain, r.url === undefined ? `https://${r.domain}/${r.id}` : r.url, r.status, r.err ?? null, r.method ?? "fetch", r.fb ?? "none")
      .run();
  }
  admin = await signIn(ADMIN);
  user = await signIn("plain@example.com");
});

describe("admin access", () => {
  it("non-admin gets 404 not_found everywhere; unauthenticated gets 401", async () => {
    for (const p of ["/parse/summary", "/parse/attempts", "/site-rules", "/site-rules/a.com"]) {
      const res = await get(user, p);
      expect(res.status).toBe(404);
      expect(await res.json()).toEqual({ error: "not_found" });
    }
    const put = await call("/v1/admin/site-rules/a.com", auth(user, { method: "PUT", body: "{}" }), undefined, env);
    expect(put.status).toBe(404);
    expect((await call("/v1/admin/parse/summary", {}, undefined, env)).status).toBe(401);
  });
  it("empty ADMIN_EMAILS means nobody is admin", async () => {
    const res = await call("/v1/admin/parse/summary", auth(admin), undefined, { ...testEnv, ADMIN_EMAILS: "" });
    expect(res.status).toBe(404);
  });
  it("/v1/me exposes isAdmin (case-insensitive match)", async () => {
    const a = (await (await call("/v1/me", auth(admin), undefined, env)).json()) as { isAdmin: boolean };
    const u = (await (await call("/v1/me", auth(user), undefined, env)).json()) as { isAdmin: boolean };
    expect(a.isAdmin).toBe(true);
    expect(u.isAdmin).toBe(false);
  });
});

describe("GET /parse/summary", () => {
  it("aggregates per domain, totals and daily series within the period", async () => {
    const res = await get(admin, "/parse/summary?days=7");
    expect(res.status).toBe(200);
    const b = (await res.json()) as any;
    expect(b.days).toBe(7);
    expect(b.totals).toEqual({ total: 6, ok: 2, partial: 1, failed: 3, renderTried: 2, renderOk: 1, renderBudgetBlocked: 1 });
    expect(b.domains.map((d: any) => d.domain)).toEqual(["a.com", "b.org"]); // sorted by failures desc
    const a = b.domains[0];
    expect(a).toMatchObject({ total: 4, ok: 1, partial: 1, failed: 2, renderTried: 2, renderOk: 1, renderBudgetBlocked: 1, lastAttemptAt: NOW - HOUR });
    expect(a.topErrors).toEqual([
      { code: "blocked", count: 2 },
      { code: "too_short", count: 1 },
    ]);
    expect(b.daily.reduce((s: number, d: any) => s + d.total, 0)).toBe(6);
    expect(b.daily[0].day).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });
  it("days=1 narrows, days=30 still excludes older, invalid days -> 400", async () => {
    expect(((await (await get(admin, "/parse/summary?days=1")).json()) as any).totals.total).toBe(5);
    expect(((await (await get(admin, "/parse/summary?days=30")).json()) as any).totals.total).toBe(6);
    expect((await get(admin, "/parse/summary?days=31")).status).toBe(400);
    expect((await get(admin, "/parse/summary?days=0")).status).toBe(400);
  });
});

describe("GET /parse/attempts", () => {
  it("newest first with keyset paging over equal timestamps", async () => {
    const seen: string[] = [];
    let cursor: string | null = null;
    for (let i = 0; i < 10; i++) {
      const res = await get(admin, `/parse/attempts?limit=2${cursor ? `&cursor=${cursor}` : ""}`);
      const b = (await res.json()) as { attempts: { id: string; createdAt: number }[]; nextCursor: string | null };
      seen.push(...b.attempts.map((a) => a.id));
      cursor = b.nextCursor;
      if (!cursor) break;
    }
    expect(seen).toEqual(["a1", "a2", "a4", "a3", "b1", "b2", "c1"]);
  });
  it("filters by domain, status, method, fallback; url null kept", async () => {
    const ids = async (qs: string) => ((await (await get(admin, `/parse/attempts?${qs}`)).json()) as any).attempts.map((a: any) => a.id);
    expect(await ids("domain=A.com&status=failed")).toEqual(["a2", "a3"]);
    expect(await ids("method=capture")).toEqual(["b1"]);
    expect(await ids("fallback=budget")).toEqual(["a3"]);
    const b = (await (await get(admin, "/parse/attempts?domain=b.org&method=capture")).json()) as any;
    expect(b.attempts[0]).toMatchObject({ url: null, ruleApplied: false, errorCode: null });
  });
  it("rejects bad params; SQL-ish input is just a string", async () => {
    expect((await get(admin, "/parse/attempts?limit=101")).status).toBe(400);
    expect((await get(admin, "/parse/attempts?status=bogus")).status).toBe(400);
    expect((await get(admin, "/parse/attempts?cursor=%%%")).status).toBe(400);
    const res = await get(admin, "/parse/attempts?domain=" + encodeURIComponent("a.com' OR '1'='1"));
    expect(((await res.json()) as any).attempts).toEqual([]);
  });
});

describe("site rules CRUD", () => {
  const put = (host: string, body: unknown) =>
    call(`/v1/admin/site-rules/${host}`, auth(admin, { method: "PUT", body: typeof body === "string" ? body : JSON.stringify(body) }), undefined, env);

  it("PUT validates, normalizes host, stamps updatedAt; GET/list/DELETE", async () => {
    const res = await put("WWW.Example.com", { render: "always", stripParams: ["utm_x"], note: "n" });
    expect(res.status).toBe(200);
    const b = (await res.json()) as any;
    expect(b.host).toBe("example.com");
    expect(b.rule).toMatchObject({ render: "always", stripParams: ["utm_x"] });
    expect(b.rule.updatedAt).toBeGreaterThan(NOW - 1000);
    expect(await testEnv.CONFIG.get("site-rules:v1:example.com")).not.toBeNull();

    const one = await get(admin, "/site-rules/example.com");
    expect(one.status).toBe(200);
    const list = (await (await get(admin, "/site-rules")).json()) as any;
    expect(list.rules.map((r: any) => r.host)).toContain("example.com");

    const del = await call("/v1/admin/site-rules/example.com", auth(admin, { method: "DELETE" }), undefined, env);
    expect(del.status).toBe(204);
    expect((await get(admin, "/site-rules/example.com")).status).toBe(404);
  });
  it("client-supplied updatedAt is overwritten; invalid bodies -> 400", async () => {
    const b = (await (await put("stamp.com", { updatedAt: 5 })).json()) as any;
    expect(b.rule.updatedAt).not.toBe(5);
    expect((await put("bad.com", { render: "sometimes" })).status).toBe(400);
    expect((await put("bad.com", { unknown: 1 })).status).toBe(400);
    expect((await put("bad.com", "{nope")).status).toBe(400);
    expect((await put("bad.com", { minTextChars: -1 })).status).toBe(400);
    expect((await put("not%20a%20host", {})).status).toBe(400);
    expect(await testEnv.CONFIG.get("site-rules:v1:bad.com")).toBeNull();
  });
});
