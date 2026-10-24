import { runInDurableObject } from "cloudflare:test";
import { type ListItemsQuery, type ParseResult, PARSER_VERSION, uuidv7 } from "@sroka/shared";
import { describe, expect, it } from "vitest";
import type { LibraryDO } from "../../src/library-do.ts";
import { T0, add, delItem, delTag, freshLibrary, rename, setFav, setStatus, tagOp } from "./helpers.ts";

const q = (over: Partial<ListItemsQuery> = {}): ListItemsQuery => ({ state: "all", sort: "newest", limit: 30, ...over });

function ok(contentId = uuidv7(), over: Partial<ParseResult> = {}): ParseResult {
  return {
    status: "ok",
    parseGen: 1,
    contentId,
    contentPrivate: false,
    title: "Parsed title",
    excerpt: "An excerpt about corvids",
    siteName: "Example",
    author: null,
    lang: "en",
    wordCount: 1000,
    readingMinutes: 4,
    leadImageKey: "thumb.webp",
    parserVersion: PARSER_VERSION,
    ...over,
  };
}

describe("LibraryDO schema", () => {
  it("migrates to the latest schema version with FTS table", async () => {
    const { lib } = freshLibrary();
    await runInDurableObject(lib, (_inst: LibraryDO, state) => {
      expect(state.storage.sql.exec("SELECT version FROM _schema").one().version).toBe(5);
      const names = state.storage.sql.exec("SELECT name FROM sqlite_master WHERE type='table'").toArray().map((r) => r.name);
      expect(names).toEqual(expect.arrayContaining(["items", "tags", "item_tags", "applied_ops", "item_aliases", "tag_renames", "items_fts", "meta"]));
    });
  });
});

describe("applyOps item.add", () => {
  it("creates an item, returns a parse job and bumps seq once", async () => {
    const { lib, userId } = freshLibrary();
    const id = uuidv7();
    const r = await lib.applyOps("devA", [add(id, "https://www.Example.com/post?utm_source=x#frag", T0, { title: "Hi", tags: ["Birds", "birds", "science"] })]);
    expect(r.response.applied).toHaveLength(1);
    expect(r.response.cursor).toBe(1);
    expect(r.parseJobs).toEqual([{ userId, itemId: id, url: "https://www.Example.com/post?utm_source=x#frag", parseGen: 1 }]);
    const item = (await lib.getItem(id))!;
    expect(item).toMatchObject({
      canonicalUrl: "https://www.example.com/post",
      title: "Hi",
      status: "unread",
      parseStatus: "pending",
      savedAt: T0,
      tags: ["Birds", "science"],
      seq: 1,
      leadImageUrl: null,
    });
    const pull = await lib.pull(0, 100);
    if (!pull.ok) throw new Error("pull");
    expect(pull.data.tags.map((t) => t.name).sort()).toEqual(["Birds", "science"]);
    expect(pull.data.tags.every((t) => t.seq === 1)).toBe(true);
  });

  it("is idempotent per (deviceId, opId)", async () => {
    const { lib } = freshLibrary();
    const op = add(uuidv7(), "https://a.example/1", T0);
    await lib.applyOps("devA", [op]);
    const again = await lib.applyOps("devA", [op]);
    expect(again.response.applied).toEqual([op.opId]);
    expect(again.parseJobs).toEqual([]);
    expect(again.response.cursor).toBe(1);
    // Same opId from another device is a different op (→ duplicate of the same URL)
    const other = await lib.applyOps("devB", [op]);
    expect(other.response.applied).toEqual([op.opId]);
  });

  it("re-add of an existing URL: readd semantics, alias stored durably and replayed", async () => {
    const { lib } = freshLibrary();
    const a = uuidv7();
    const b = uuidv7();
    await lib.applyOps("devA", [add(a, "https://a.example/x", T0, { tags: ["one"] }), setStatus(a, "archived", T0 + 10)]);
    const addB = add(b, "https://a.example/x?utm_medium=y", T0 + 20, { tags: ["two"], title: "ignored?" });
    const r = await lib.applyOps("devB", [addB]);
    expect(r.response.aliases).toEqual({ [b]: a });
    const item = (await lib.getItem(a))!;
    expect(item).toMatchObject({ status: "unread", archivedAt: null, savedAt: T0 + 20, tags: ["one", "two"], title: "ignored?" });
    // replay reports the alias again
    const replay = await lib.applyOps("devB", [addB]);
    expect(replay.response.aliases).toEqual({ [b]: a });
    // a later op queued on the client id applies to the target
    const fav = await lib.applyOps("devB", [setFav(b, true, T0 + 30)]);
    expect(fav.response.applied).toHaveLength(1);
    expect((await lib.getItem(a))!.isFavorite).toBe(true);
    expect((await lib.getItem(b))!.id).toBe(a);
  });

  it("merge duplicates only union tags; readd loses to a newer status", async () => {
    const { lib } = freshLibrary();
    const a = uuidv7();
    await lib.applyOps("devA", [add(a, "https://m.example/", T0), setStatus(a, "archived", T0 + 100)]);
    await lib.applyOps("import", [add(uuidv7(), "https://m.example/", T0 + 200, { onDuplicate: "merge", tags: ["imp"] })]);
    expect(await lib.getItem(a)).toMatchObject({ status: "archived", savedAt: T0, tags: ["imp"] });
    await lib.applyOps("devB", [add(uuidv7(), "https://m.example/", T0 + 50)]); // older than archive
    expect(await lib.getItem(a)).toMatchObject({ status: "archived" });
  });

  it("re-queues parsing only for failed duplicates", async () => {
    const { lib } = freshLibrary();
    const a = uuidv7();
    await lib.applyOps("devA", [add(a, "https://f.example/", T0)]);
    expect((await lib.applyOps("devA", [add(uuidv7(), "https://f.example/", T0 + 1)])).parseJobs).toEqual([]);
    expect(await lib.markParsed(a, { ...ok(), status: "failed", contentId: undefined, error: "http_404" })).toEqual({ ok: true });
    const r = await lib.applyOps("devA", [add(uuidv7(), "https://f.example/", T0 + 2)]);
    expect(r.parseJobs).toHaveLength(1);
    expect(r.parseJobs[0]!.parseGen).toBe(2);
    expect((await lib.getItem(a))!.parseStatus).toBe("pending");
  });

  it("rejects invalid ops individually", async () => {
    const { lib } = freshLibrary();
    const r = await lib.applyOps("devA", [
      { opId: "bad1", type: "item.nope", at: 1 },
      add(uuidv7(), "ftp://x.example/", T0),
      setStatus(uuidv7(), "archived", T0),
      add(uuidv7(), "https://ok.example/", T0),
    ]);
    expect(r.response.applied).toHaveLength(1);
    expect(r.response.rejected.map((x) => x.reason).sort()).toEqual(["invalid_op", "invalid_op", "unknown_item"]);
  });
});

describe("LWW and delete", () => {
  it("per-field LWW with device tie-break; losers are applied without seq bump", async () => {
    const { lib } = freshLibrary();
    const a = uuidv7();
    await lib.applyOps("devA", [add(a, "https://l.example/", T0), setStatus(a, "archived", T0 + 10)]);
    const seq = (await lib.getItem(a))!.seq;
    const lose = await lib.applyOps("devA", [setStatus(a, "unread", T0 + 5)]);
    expect(lose.response.applied).toHaveLength(1);
    expect(await lib.getItem(a)).toMatchObject({ status: "archived", archivedAt: T0 + 10, seq });
    await lib.applyOps("devB", [setStatus(a, "unread", T0 + 10)]); // same at, higher dev wins
    expect((await lib.getItem(a))!.status).toBe("unread");
    await lib.applyOps("devA", [setStatus(a, "archived", T0 + 10)]); // same at, lower dev loses
    expect((await lib.getItem(a))!.status).toBe("unread");
    // future at is clamped to now + 5 min
    await lib.applyOps("devA", [setFav(a, true, Date.now() + 10 * 86400_000)]);
    await lib.applyOps("devB", [setFav(a, false, Date.now() + 4 * 60_000)]);
    expect((await lib.getItem(a))!.isFavorite).toBe(true);
  });

  it("progress + title ops", async () => {
    const { lib } = freshLibrary();
    const a = uuidv7();
    await lib.applyOps("d", [
      add(a, "https://p.example/", T0, { title: "Provisional" }),
      { opId: "p1", type: "item.setProgress", itemId: a, progress: 0.5, anchor: 3, at: T0 + 5 },
      { opId: "t1", type: "item.setTitle", itemId: a, title: "Mine", at: T0 + 6 },
    ]);
    expect(await lib.getItem(a)).toMatchObject({ progress: 0.5, progressAnchor: 3, lastReadAt: T0 + 5, title: "Mine" });
    await lib.markParsed(a, ok());
    expect((await lib.getItem(a))!.title).toBe("Mine");
    await lib.applyOps("d", [{ opId: "t2", type: "item.setTitle", itemId: a, title: "", at: T0 + 7 }]);
    expect((await lib.getItem(a))!.title).toBe("Parsed title");
  });

  it("delete wins; re-save after delete creates a new item", async () => {
    const { lib } = freshLibrary();
    const a = uuidv7();
    await lib.applyOps("d", [add(a, "https://d.example/", T0), delItem(a, T0 + 1)]);
    const later = await lib.applyOps("d", [setFav(a, true, T0 + 100), delItem(a, T0 + 101), add(a, "https://d.example/", T0 + 102)]);
    expect(later.response.rejected.map((r) => r.reason)).toEqual(["item_deleted", "item_deleted"]);
    expect(later.response.applied).toHaveLength(1); // second delete = applied no-op
    expect(await lib.getItem(a)).toBeNull();
    const b = uuidv7();
    const r = await lib.applyOps("d", [add(b, "https://d.example/", T0 + 200)]);
    expect(r.response.aliases).toEqual({});
    expect(await lib.getItem(b)).not.toBeNull();
    const pull = await lib.pull(0, 100);
    if (!pull.ok) throw new Error();
    expect(pull.data.deleted.items).toEqual([a]);
    expect(pull.data.items.map((i) => i.id)).toEqual([b]);
  });
});

describe("tags", () => {
  it("case-insensitive identity, rename in place, merge, delete, stale ops", async () => {
    const { lib } = freshLibrary();
    const a = uuidv7();
    const b = uuidv7();
    await lib.applyOps("d", [
      add(a, "https://t.example/a", T0, { tags: ["Żółw"] }),
      add(b, "https://t.example/b", T0, { tags: ["żółw", "ml"] }),
    ]);
    let tags = await lib.listTags();
    expect(tags.map((t) => [t.name, t.count])).toEqual([["ml", 1], ["Żółw", 2]]);

    // in-place rename
    await lib.applyOps("d", [rename("ml", "Machine Learning", T0 + 100)]);
    expect((await lib.getItem(b))!.tags).toEqual(["Machine Learning", "Żółw"]);
    // stale op (older than rename) on the old name targets the renamed tag
    await lib.applyOps("d2", [tagOp(a, "ml", true, T0 + 50)]);
    expect((await lib.getItem(a))!.tags).toEqual(["Machine Learning", "Żółw"]);
    // newer op on the old name creates a new tag
    await lib.applyOps("d2", [tagOp(a, "ML", true, T0 + 150)]);
    expect((await lib.getItem(a))!.tags).toEqual(["Machine Learning", "ML", "Żółw"]);

    // merge "ML" into "żółw"
    await lib.applyOps("d", [rename("ml", "ŻÓŁW", T0 + 200)]);
    tags = await lib.listTags();
    expect(tags.map((t) => [t.name, t.count])).toEqual([["Machine Learning", 2], ["Żółw", 2]]);

    // delete; stale add is a no-op, newer add creates a new tag
    await lib.applyOps("d", [delTag("machine learning", T0 + 300)]);
    expect((await lib.getItem(a))!.tags).toEqual(["Żółw"]);
    await lib.applyOps("d2", [tagOp(a, "Machine Learning", true, T0 + 250)]);
    expect((await lib.getItem(a))!.tags).toEqual(["Żółw"]);
    await lib.applyOps("d2", [tagOp(a, "machine learning", true, T0 + 350)]);
    expect((await lib.getItem(a))!.tags).toEqual(["machine learning", "Żółw"]);

    const r = await lib.applyOps("d", [rename("nope", "x", T0 + 400), delTag("nope", T0 + 400)]);
    expect(r.response.rejected.map((x) => x.reason)).toEqual(["unknown_tag", "unknown_tag"]);
  });

  it("pair LWW is order independent", async () => {
    const { lib } = freshLibrary();
    const a = uuidv7();
    await lib.applyOps("d", [add(a, "https://pl.example/", T0, { tags: ["x"] })]);
    await lib.applyOps("d", [tagOp(a, "x", false, T0 + 20), tagOp(a, "x", true, T0 + 10)]);
    expect((await lib.getItem(a))!.tags).toEqual([]);
  });

  it("rejects more than 100 tags", async () => {
    const { lib } = freshLibrary();
    const a = uuidv7();
    const tags = Array.from({ length: 100 }, (_, i) => `t${i}`);
    await lib.applyOps("d", [add(a, "https://many.example/", T0, { tags })]);
    const r = await lib.applyOps("d", [tagOp(a, "one-more", true, T0 + 1)]);
    expect(r.response.rejected).toEqual([{ opId: expect.any(String), reason: "too_many_tags" }]);
  });

  it("suggestions: recent, frequent, current", async () => {
    const { lib } = freshLibrary();
    const ids = [uuidv7(), uuidv7(), uuidv7()];
    await lib.applyOps("d", [
      add(ids[0]!, "https://s.example/0", T0, { tags: ["old", "common"] }),
      add(ids[1]!, "https://s.example/1", T0 + 10, { tags: ["common"] }),
      add(ids[2]!, "https://s.example/2", T0 + 20, { tags: ["new"] }),
    ]);
    const s = await lib.suggestions("https://s.example/0");
    expect(s.recent).toEqual(["new", "common", "old"]);
    expect(s.frequent).toEqual([]);
    expect(s.current).toEqual(["common", "old"]);
    expect((await lib.suggestions(null)).current).toEqual([]);
  });
});

describe("sync pull", () => {
  it("never splits a seq group (rename across more items than limit)", async () => {
    const { lib } = freshLibrary();
    const ops = Array.from({ length: 25 }, (_, i) => add(uuidv7(), `https://g.example/${i}`, T0 + i, { tags: ["grp"] }));
    await lib.applyOps("d", ops);
    const before = (await lib.applyOps("d", [])).response.cursor;
    await lib.applyOps("d", [add(uuidv7(), "https://g.example/x", T0 + 100)]);
    await lib.applyOps("d", [rename("grp", "group", T0 + 200)]);
    await lib.applyOps("d", [add(uuidv7(), "https://g.example/y", T0 + 300)]);
    const seen = new Map<string, number>();
    let tagSeen = 0;
    let cursor = before;
    let pages = 0;
    for (;;) {
      const r = await lib.pull(cursor, 4);
      if (!r.ok) throw new Error("410");
      pages++;
      for (const it of r.data.items) seen.set(it.id, (seen.get(it.id) ?? 0) + 1);
      tagSeen += r.data.tags.length;
      cursor = r.data.cursor;
      if (!r.data.hasMore) break;
    }
    expect(seen.size).toBe(27);
    expect([...seen.values()].every((n) => n === 1)).toBe(true);
    expect(tagSeen).toBe(1);
    expect(pages).toBe(2); // page 1 = x + the whole 26-row rename group (exceeds limit 4), page 2 = y
    expect(cursor).toBe(before + 3);
  });

  it("returns 410 when cursor is older than the tombstone horizon", async () => {
    const { lib } = freshLibrary();
    const a = uuidv7();
    await lib.applyOps("d", [add(a, "https://h.example/", T0), delItem(a, T0 + 1), add(uuidv7(), "https://h2.example/", T0 + 2)]);
    await runInDurableObject(lib, (inst: LibraryDO) => {
      (inst as unknown as { store: { prune(now: number): void } }).store.prune(Date.now() + 181 * 86400_000);
    });
    expect(await lib.pull(1, 10)).toEqual({ ok: false, error: "resync_required" });
    const fromZero = await lib.pull(0, 10);
    expect(fromZero.ok).toBe(true);
    const ok2 = await lib.pull(2, 10);
    expect(ok2.ok).toBe(true);
  });

  it("full=1 pages a pass from 0 past a purged tombstone without 410", async () => {
    const { lib } = freshLibrary();
    const gone = uuidv7();
    const ids = Array.from({ length: 6 }, () => uuidv7());
    await lib.applyOps("d", [add(gone, "https://g.example/", T0), delItem(gone, T0 + 1)]);
    await lib.applyOps("d", ids.map((id, i) => add(id, `https://live${i}.example/`, T0 + 10 + i)));
    await runInDurableObject(lib, (inst: LibraryDO) => {
      (inst as unknown as { store: { prune(now: number): void } }).store.prune(Date.now() + 181 * 86400_000);
    });
    const seen = new Set<string>();
    let cursor = 0;
    let pages = 0;
    for (;;) {
      const r = await lib.pull(cursor, 2, true);
      if (!r.ok) throw new Error("410");
      pages++;
      for (const it of r.data.items) seen.add(it.id);
      cursor = r.data.cursor;
      if (!r.data.hasMore) break;
    }
    expect(pages).toBeGreaterThan(1);
    expect(seen.size).toBe(6);
    // Same mid-pass cursor without full still demands a resync.
    expect(await lib.pull(1, 2)).toEqual({ ok: false, error: "resync_required" });
  });
});

describe("list / search", () => {
  async function seeded() {
    const { lib } = freshLibrary();
    const ids = Array.from({ length: 6 }, () => uuidv7());
    await lib.applyOps("d", [
      add(ids[0]!, "https://www.nytimes.com/a", T0 + 1, { tags: ["news"] }),
      add(ids[1]!, "https://cooking.nytimes.com/b", T0 + 2, { title: "Pasta recipe" }),
      add(ids[2]!, "https://notnytimes.com/c", T0 + 3),
      add(ids[3]!, "https://example.org/d", T0 + 4, { title: "Corvid intelligence" }),
      add(ids[4]!, "https://example.org/e", T0 + 5),
      add(ids[5]!, "https://example.org/f", T0 + 6),
      setStatus(ids[4]!, "archived", T0 + 10),
      setFav(ids[5]!, true, T0 + 10),
    ]);
    await lib.markParsed(ids[0]!, ok(uuidv7(), { wordCount: 300, title: "Magpies of Manhattan", excerpt: "Birds" }));
    await lib.markParsed(ids[2]!, ok(uuidv7(), { wordCount: 100, title: "Other" }));
    await lib.markParsed(ids[3]!, ok(uuidv7(), { wordCount: 200, title: null }));
    return { lib, ids };
  }

  it("filters by state, tag, domain, url", async () => {
    const { lib, ids } = await seeded();
    const unread = await lib.listItems(q({ state: "unread" }));
    if (!unread.ok) throw new Error();
    expect(unread.items.map((i) => i.id)).toEqual([ids[5], ids[3], ids[2], ids[1], ids[0]]);
    const arch = await lib.listItems(q({ state: "archived" }));
    expect(arch.ok && arch.items.map((i) => i.id)).toEqual([ids[4]]);
    const fav = await lib.listItems(q({ state: "favorites" }));
    expect(fav.ok && fav.items.map((i) => i.id)).toEqual([ids[5]]);
    const tag = await lib.listItems(q({ tag: "NEWS" }));
    expect(tag.ok && tag.items.map((i) => i.id)).toEqual([ids[0]]);
    const dom = await lib.listItems(q({ domain: "www.NYTimes.com" }));
    expect(dom.ok && dom.items.map((i) => i.id)).toEqual([ids[1], ids[0]]);
    const url = await lib.listItems(q({ url: "https://example.org/d#x" }), "https://example.org/d");
    expect(url.ok && url.items.map((i) => i.id)).toEqual([ids[3]]);
  });

  it("searches with FTS (prefix, AND, tags, odd input)", async () => {
    const { lib, ids } = await seeded();
    const s = async (text: string) => {
      const r = await lib.listItems(q({ q: text }));
      if (!r.ok) throw new Error();
      return r.items.map((i) => i.id);
    };
    expect(await s("magp")).toEqual([ids[0]]);
    expect(await s("magpies manh")).toEqual([ids[0]]);
    expect(await s("magpies pasta")).toEqual([]);
    expect(await s("news")).toEqual([ids[0]]);
    expect(await s("intellig")).toEqual([ids[3]]);
    expect(await s("corvids")).toEqual([ids[3], ids[2]]); // provisional title kept when parsed title is null
    expect(await s('") OR * NEAR( ^')).toEqual([]);
    expect(await s("AND")).toEqual([]);
  });

  it("sorts and pages with keyset cursors", async () => {
    const { lib, ids } = await seeded();
    const all = async (sort: ListItemsQuery["sort"]) => {
      const out: string[] = [];
      let cursor: string | undefined;
      for (;;) {
        const r = await lib.listItems(q({ sort, limit: 2, ...(cursor ? { cursor } : {}) }));
        if (!r.ok) throw new Error();
        out.push(...r.items.map((i) => i.id));
        if (!r.nextCursor) break;
        cursor = r.nextCursor;
      }
      return out;
    };
    expect(await all("newest")).toEqual([...ids].reverse());
    expect(await all("oldest")).toEqual(ids);
    const nulls = [ids[1]!, ids[4]!, ids[5]!].sort();
    expect(await all("shortest")).toEqual([ids[2], ids[3], ids[0], ...nulls]);
    expect(await all("longest")).toEqual([ids[0], ids[3], ids[2], ...[...nulls].reverse()]);
    expect(await lib.listItems(q({ cursor: "garbage" }))).toEqual({ ok: false, error: "bad_cursor" });
  });
});

describe("parse pipeline", () => {
  it("markParsed honours parseGen and failed results keep content", async () => {
    const { lib, userId } = freshLibrary();
    const a = uuidv7();
    await lib.applyOps("d", [add(a, "https://pp.example/", T0)]);
    const cid = uuidv7();
    expect(await lib.markParsed(a, ok(cid, { parseGen: 0 }))).toEqual({ ok: false });
    expect(await lib.markParsed(uuidv7(), ok(cid))).toEqual({ ok: false });
    expect(await lib.markParsed(a, ok(cid, { contentPrivate: true }))).toEqual({ ok: true });
    let item = (await lib.getItem(a))!;
    expect(item).toMatchObject({ contentId: cid, contentPrivate: true, parseStatus: "ok", wordCount: 1000, leadImageKey: "thumb.webp" });
    expect(item.leadImageUrl).toMatch(new RegExp(`^http://127\\.0\\.0\\.1:8787/s/\\d+/[A-Za-z0-9_-]{43}/u\\.${userId}/${cid}/thumb\\.webp$`));

    const refresh = await lib.applyOps("d", [{ opId: "r1", type: "item.refresh", itemId: a, at: T0 + 1 }]);
    expect(refresh.parseJobs).toEqual([{ userId, itemId: a, url: "https://pp.example/", force: true, parseGen: 2 }]);
    const job = await lib.requestParse(a, { rawKey: "raw/x", force: true });
    expect(job).toMatchObject({ parseGen: 3, rawKey: "raw/x" });
    expect(await lib.markParsed(a, { ...ok(), parseGen: 2 })).toEqual({ ok: false });
    expect(await lib.markParsed(a, { ...ok(), status: "failed", contentId: undefined, parseGen: 3, error: "timeout", title: "zzz" })).toEqual({ ok: true });
    item = (await lib.getItem(a))!;
    expect(item).toMatchObject({ contentId: cid, contentPrivate: true, parseStatus: "failed", parseError: "timeout", title: "Parsed title" });
    expect(await lib.requestParse(uuidv7())).toBeNull();
  });
});

describe("account wipe", () => {
  it("destroy() deletes everything and leaves a tombstone: later writes can't recreate the library", async () => {
    const { lib } = freshLibrary();
    const id = uuidv7();
    await lib.applyOps("d", [add(id, "https://w.example/", T0)]);
    await lib.destroy();
    await runInDurableObject(lib, async (inst: LibraryDO) => {
      await expect(inst.applyOps("d", [add(uuidv7(), "https://late.example/", T0)])).rejects.toThrow(/library_destroyed/);
      await expect(inst.pull(0, 10)).rejects.toThrow(/library_destroyed/);
    });
    // A late parser result / pre-check is refused instead of migrating a fresh schema.
    expect(await lib.parseWanted(id, 1)).toBe(false);
    expect(
      await lib.markParsed(id, { status: "failed", parseGen: 1, contentPrivate: false, title: null, excerpt: null, siteName: null, author: null, lang: null, wordCount: null, readingMinutes: null, error: "x", parserVersion: 1 }),
    ).toEqual({ ok: false });
    await runInDurableObject(lib, async (inst: LibraryDO, state) => {
      expect(await state.storage.getAlarm()).toBeNull();
      await inst.alarm(); // a retried alarm must not resurrect the schema or reschedule itself
      expect(await state.storage.getAlarm()).toBeNull();
      const tables = state.storage.sql.exec("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'items'").toArray();
      expect(tables).toEqual([]);
    });
  });
});
