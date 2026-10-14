// Shared-content references (LibraryDO → D1 content_refs) and the parser GC, end to end against the real
// LibraryDO class (test/entry.ts) and the real D1 migrations. api.md §9 "Content references / GC".
import { runDurableObjectAlarm } from "cloudflare:test";
import { env as rawEnv } from "cloudflare:workers";
import { PARSER_VERSION, r2Keys, uuidv7, normalizeUrl, urlHash, type ParseResult } from "@sroka/shared";
import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { LibraryDO } from "../../api/src/library-do.ts";
import { CONTENT_GC_GRACE_MS, GC_KEYS, backfillContentRefs, sweepSharedContent } from "../src/gc.ts";
import type { ParserEnv } from "../src/env.ts";
import { processJob } from "../src/process.ts";
import { addUser, migrateD1 } from "./d1.ts";

const env = rawEnv as unknown as Omit<ParserEnv, "LIBRARY"> & { LIBRARY: DurableObjectNamespace<LibraryDO> };
const DB = env.DB;
const DAY = 86_400_000;
const OLD = Date.now() - CONTENT_GC_GRACE_MS - DAY;

let n = 0;
async function freshUser(prefix = "gc") {
  const userId = `${prefix}_${Date.now().toString(36)}_${++n}`;
  await addUser(DB, userId);
  return { userId, lib: env.LIBRARY.getByName(userId) };
}

/** Simulates the parser output: a content row + its R2 dir. */
async function makeContent(opts: { lastUsedAt?: number; url?: string } = {}): Promise<string> {
  const id = uuidv7();
  const canonical = normalizeUrl(opts.url ?? `https://example.com/${id}`);
  const at = opts.lastUsedAt ?? Date.now();
  await DB.prepare(
    `INSERT INTO content (id, url_hash, canonical_url, parser_version, status, parsed_at, cacheable, last_used_at)
     VALUES (?1, ?2, ?3, ?4, 'ok', ?5, 1, ?5)`,
  )
    .bind(id, await urlHash(canonical), canonical, PARSER_VERSION, at)
    .run();
  for (const f of ["article.html", "text.txt", "img/a.webp"]) await env.CONTENT.put(r2Keys.contentDir(id) + f, "x");
  await env.CONTENT.put(r2Keys.contentDir(id) + "meta.json", JSON.stringify({ status: "ok", title: "T", excerpt: null, siteName: null, author: null, lang: null, wordCount: 1, readingMinutes: 1 }));
  return id;
}

const ok = (parseGen: number, contentId: string, contentPrivate = false): ParseResult => ({
  status: "ok",
  parseGen,
  contentId,
  contentPrivate,
  title: "T",
  excerpt: null,
  siteName: null,
  author: null,
  lang: null,
  wordCount: 1,
  readingMinutes: 1,
  parserVersion: PARSER_VERSION,
});
const failed = (parseGen: number): ParseResult => ({ ...ok(parseGen, uuidv7()), status: "failed", contentId: undefined, error: "http_500" });

async function addItem(lib: DurableObjectStub<LibraryDO>, url: string, itemId = uuidv7()): Promise<{ itemId: string; gen: number }> {
  const r = await lib.applyOps("dev", [{ opId: uuidv7(), type: "item.add", itemId, url, at: Date.now() }]);
  return { itemId, gen: r.parseJobs[0]!.parseGen };
}
async function refresh(lib: DurableObjectStub<LibraryDO>, itemId: string): Promise<number> {
  // Not coalesced: the previous parse already finished (item not pending).
  const r = await lib.applyOps("dev", [{ opId: uuidv7(), type: "item.refresh", itemId, at: Date.now() }]);
  return r.parseJobs[0]!.parseGen;
}
async function del(lib: DurableObjectStub<LibraryDO>, itemId: string): Promise<void> {
  await lib.applyOps("dev", [{ opId: uuidv7(), type: "item.delete", itemId, at: Date.now() }]);
}
async function refs(contentId: string): Promise<string[]> {
  const r = await DB.prepare("SELECT user_id FROM content_refs WHERE content_id = ?1 ORDER BY user_id").bind(contentId).all<{ user_id: string }>();
  return r.results.map((x) => x.user_id);
}
async function row(contentId: string) {
  return DB.prepare("SELECT ref_count, last_used_at, gc_at FROM content WHERE id = ?1").bind(contentId).first<{ ref_count: number; last_used_at: number; gc_at: number | null }>();
}
async function r2Count(contentId: string): Promise<number> {
  return (await env.CONTENT.list({ prefix: r2Keys.contentDir(contentId) })).objects.length;
}
async function backfillDone(): Promise<void> {
  await DB.prepare("INSERT OR REPLACE INTO gc_state (k, v) VALUES (?1, '1')").bind(GC_KEYS.done).run();
}

beforeAll(async () => {
  await migrateD1(DB);
});
beforeEach(async () => {
  await DB.exec("DELETE FROM content");
  await DB.exec("DELETE FROM content_refs");
  await DB.exec("DELETE FROM gc_state");
});

describe("LibraryDO content refs (D1 content_refs)", () => {
  it("attaches on parse, moves on refresh, keeps on failed re-parse, detaches on delete", async () => {
    const { userId, lib } = await freshUser();
    const c1 = await makeContent({ lastUsedAt: OLD });
    const c2 = await makeContent();
    const { itemId, gen } = await addItem(lib, "https://example.com/a");
    expect(await lib.markParsed(itemId, ok(gen, c1))).toEqual({ ok: true });
    expect(await refs(c1)).toEqual([userId]);
    // attach refreshes the grace period and the ref_count cache
    expect((await row(c1))!.ref_count).toBe(1);
    expect((await row(c1))!.last_used_at).toBeGreaterThan(OLD);

    const g2 = await refresh(lib, itemId);
    expect(await refs(c1)).toEqual([userId]); // still readable while the refresh is pending
    await lib.markParsed(itemId, ok(g2, c2));
    expect(await refs(c1)).toEqual([]);
    expect((await row(c1))!.ref_count).toBe(0);
    expect(await refs(c2)).toEqual([userId]);

    const g3 = await refresh(lib, itemId);
    await lib.markParsed(itemId, failed(g3));
    expect(await refs(c2)).toEqual([userId]); // failed re-parse keeps the earlier content

    await del(lib, itemId);
    expect(await refs(c2)).toEqual([]);
  });

  it("private content never creates refs; switching public → private detaches", async () => {
    const { lib } = await freshUser();
    const pub = await makeContent();
    const { itemId, gen } = await addItem(lib, "https://example.com/p");
    await lib.markParsed(itemId, ok(gen, pub));
    expect(await refs(pub)).toHaveLength(1);
    const job = await lib.requestParse(itemId, { rawKey: `raw/x/${itemId}.html.gz` });
    const priv = uuidv7();
    await lib.markParsed(itemId, ok(job!.parseGen, priv, true));
    expect(await refs(pub)).toEqual([]);
    expect(await refs(priv)).toEqual([]);
  });

  it("refs are per user; a re-saved (new) item re-attaches the same cached content", async () => {
    const a = await freshUser();
    const b = await freshUser();
    const c = await makeContent();
    const ia = await addItem(a.lib, "https://example.com/shared");
    const ib = await addItem(b.lib, "https://example.com/shared");
    await a.lib.markParsed(ia.itemId, ok(ia.gen, c));
    await b.lib.markParsed(ib.itemId, ok(ib.gen, c));
    expect(await refs(c)).toEqual([a.userId, b.userId].sort());
    expect((await row(c))!.ref_count).toBe(2);
    await del(a.lib, ia.itemId);
    expect(await refs(c)).toEqual([b.userId]);
    // Items can't be undeleted; saving the URL again creates a new item that attaches again.
    const again = await addItem(a.lib, "https://example.com/shared");
    expect(again.itemId).not.toBe(ia.itemId);
    await a.lib.markParsed(again.itemId, ok(again.gen, c));
    expect(await refs(c)).toEqual([a.userId, b.userId].sort());
  });

  it("account destroy detaches every ref of the user", async () => {
    const { userId, lib } = await freshUser();
    const c = await makeContent();
    const { itemId, gen } = await addItem(lib, "https://example.com/d");
    await lib.markParsed(itemId, ok(gen, c));
    expect(await refs(c)).toEqual([userId]);
    await lib.destroy();
    expect(await refs(c)).toEqual([]);
    expect(await lib.reemitContentRefs()).toEqual({ refs: 0, pending: 0 });
  });

  it("outbox: a failed D1 flush is retried (next request / alarm) and re-emits are idempotent", async () => {
    const { userId, lib } = await freshUser();
    const c = await makeContent();
    const { itemId, gen } = await addItem(lib, "https://example.com/o");
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    await DB.exec("ALTER TABLE content_refs RENAME TO content_refs_off");
    try {
      expect(await lib.markParsed(itemId, ok(gen, c))).toEqual({ ok: true }); // the parse result still commits
    } finally {
      await DB.exec("ALTER TABLE content_refs_off RENAME TO content_refs");
      err.mockRestore();
    }
    expect(await refs(c)).toEqual([]);
    // The failed flush scheduled an early alarm; the alarm flushes the outbox.
    expect(await runDurableObjectAlarm(lib)).toBe(true);
    expect(await refs(c)).toEqual([userId]);
    // Re-emitting (backfill) twice is harmless.
    expect(await lib.reemitContentRefs()).toEqual({ refs: 1, pending: 0 });
    expect(await lib.reemitContentRefs()).toEqual({ refs: 1, pending: 0 });
    expect(await refs(c)).toEqual([userId]);
    expect((await row(c))!.ref_count).toBe(1);
  });
});

describe("shared-content GC (parser cron)", () => {
  it("is a no-op until the backfill is done", async () => {
    const c = await makeContent({ lastUsedAt: OLD });
    expect(await sweepSharedContent(env)).toMatchObject({ skipped: "backfill_pending", rows: 0 });
    expect(await r2Count(c)).toBe(4);
    expect(await row(c)).not.toBeNull();
    // Starting the backfill alone doesn't enable it either.
    await DB.prepare("INSERT INTO gc_state (k, v) VALUES (?1, 'start')").bind(GC_KEYS.start).run();
    expect(await sweepSharedContent(env)).toMatchObject({ skipped: "backfill_pending" });
    expect(await r2Count(c)).toBe(4);
  });

  it("backfill re-emits existing refs for every user, then enables GC (which keeps them)", async () => {
    const { userId, lib } = await freshUser("bf");
    const c = await makeContent({ lastUsedAt: OLD });
    const { itemId, gen } = await addItem(lib, "https://example.com/bf");
    await lib.markParsed(itemId, ok(gen, c));
    // Pre-feature state: the item references c, D1 has no ref row and an old last_used_at.
    await DB.exec("DELETE FROM content_refs");
    await DB.prepare("UPDATE content SET last_used_at = ?1").bind(OLD).run();

    expect(await backfillContentRefs(env)).toMatchObject({ state: "not_started" });
    await DB.prepare("INSERT INTO gc_state (k, v) VALUES (?1, 'start')").bind(GC_KEYS.start).run();
    // Paged: one user per run until the user table is exhausted.
    let r = await backfillContentRefs(env, 1);
    for (let i = 0; r.state === "in_progress" && i < 1000; i++) r = await backfillContentRefs(env, 1);
    expect(r.state).toBe("done");
    expect(await refs(c)).toEqual([userId]);
    expect(await backfillContentRefs(env)).toMatchObject({ state: "done", users: 0 });

    const g = await sweepSharedContent(env);
    expect(g.skipped).toBeUndefined();
    expect(await r2Count(c)).toBe(4);
  });

  it("deletes only unreferenced content past the grace period (R2 dir + row)", async () => {
    await backfillDone();
    const { lib } = await freshUser();
    const oldFree = await makeContent({ lastUsedAt: OLD });
    const newFree = await makeContent();
    const oldUsed = await makeContent({ lastUsedAt: OLD });
    const { itemId, gen } = await addItem(lib, "https://example.com/used");
    await lib.markParsed(itemId, ok(gen, oldUsed));
    await DB.prepare("UPDATE content SET last_used_at = ?1 WHERE id = ?2").bind(OLD, oldUsed).run();

    const r = await sweepSharedContent(env);
    expect(r).toMatchObject({ rows: 1, objects: 4, rescued: 0 });
    expect(await row(oldFree)).toBeNull();
    expect(await r2Count(oldFree)).toBe(0);
    expect(await r2Count(newFree)).toBe(4);
    expect(await r2Count(oldUsed)).toBe(4);

    // Once the last item is deleted, the content waits a full grace period from the detach.
    await del(lib, itemId);
    expect(await sweepSharedContent(env)).toMatchObject({ rows: 0 });
    expect(await r2Count(oldUsed)).toBe(4);
    expect(await sweepSharedContent(env, Date.now() + CONTENT_GC_GRACE_MS + DAY)).toMatchObject({ rows: 2 }); // oldUsed + newFree
    expect(await r2Count(oldUsed)).toBe(0);
  });

  it("drops refs of deleted users, bounds work per run and resumes marked rows", async () => {
    await backfillDone();
    const ids = [await makeContent({ lastUsedAt: OLD }), await makeContent({ lastUsedAt: OLD }), await makeContent({ lastUsedAt: OLD })];
    await DB.prepare("INSERT INTO content_refs (content_id, user_id, at) VALUES (?1, 'ghost-user', 1)").bind(ids[0]).run();
    const r1 = await sweepSharedContent(env, Date.now(), { rows: 2 });
    expect(r1).toMatchObject({ deadRefs: 1, rows: 2 });
    // Interrupted run: a marked row is resumed first next time.
    await DB.prepare("UPDATE content SET gc_at = 1 WHERE id IN (SELECT id FROM content)").run();
    const r2 = await sweepSharedContent(env, Date.now(), { rows: 2 });
    expect(r2).toMatchObject({ rows: 1 });
    expect((await DB.prepare("SELECT COUNT(*) AS n FROM content").first<{ n: number }>())!.n).toBe(0);
  });

  it("re-checks refs right before deleting: a marked row that got referenced is kept", async () => {
    await backfillDone();
    const { userId, lib } = await freshUser();
    const c = await makeContent({ lastUsedAt: OLD });
    const { itemId, gen } = await addItem(lib, "https://example.com/late");
    await DB.prepare("UPDATE content SET gc_at = 1 WHERE id = ?1").bind(c).run();
    await lib.markParsed(itemId, ok(gen, c)); // late DO flush after the mark
    const r = await sweepSharedContent(env);
    expect(r).toMatchObject({ rows: 0, rescued: 1 });
    expect(await r2Count(c)).toBe(4);
    expect((await row(c))!.gc_at).toBeNull();
    expect(await refs(c)).toEqual([userId]);
  });

  it("a shared-cache hit touches the row so the GC keeps it", async () => {
    await backfillDone();
    const url = "https://example.com/cached";
    const c = await makeContent({ url });
    // Parsed 2 days ago (still a valid cache entry) but last used long ago and unreferenced.
    await DB.prepare("UPDATE content SET parsed_at = ?1, last_used_at = ?2 WHERE id = ?3").bind(Date.now() - 2 * DAY, OLD, c).run();
    const res = await processJob(env, { userId: "u", itemId: uuidv7(), url, parseGen: 1 }, {
      fetch: async () => {
        throw new Error("no fetch on a cache hit");
      },
      now: () => Date.now(),
      newId: () => uuidv7(),
    });
    expect(res?.contentId).toBe(c);
    expect(await sweepSharedContent(env)).toMatchObject({ rows: 0 });
    expect(await r2Count(c)).toBe(4);
  });
});
