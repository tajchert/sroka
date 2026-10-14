import { runInDurableObject } from "cloudflare:test";
import { type OpInput, type ParseResult, PARSER_VERSION, uuidv7 } from "@sroka/shared";
import { describe, expect, it } from "vitest";
import type { LibraryStore } from "../../src/do/store.ts";
import { MAX_SEQ_GROUP } from "../../src/do/store.ts";
import type { LibraryDO } from "../../src/library-do.ts";
import { T0, add, delItem, delTag, freshLibrary, rename, tagOp, testEnv } from "./helpers.ts";

const storeOf = (inst: LibraryDO) => (inst as unknown as { store: LibraryStore }).store;

function ok(over: Partial<ParseResult> = {}): ParseResult {
  return {
    status: "ok",
    parseGen: 1,
    contentId: uuidv7(),
    contentPrivate: false,
    title: "T",
    excerpt: "E",
    siteName: null,
    author: null,
    lang: "en",
    wordCount: 10,
    readingMinutes: 1,
    parserVersion: PARSER_VERSION,
    ...over,
  };
}
const failed = (gen: number): ParseResult => ({ ...ok({ parseGen: gen }), status: "failed", contentId: undefined, error: "parse_failed" });
const refresh = (itemId: string, at: number): OpInput => ({ opId: uuidv7(), type: "item.refresh", itemId, at });

describe("security hardening (LibraryDO)", () => {
  it("markParsed accepts one result per gen: a duplicate or a later DLQ 'failed' can't overwrite a success", async () => {
    const { lib } = freshLibrary();
    const a = uuidv7();
    await lib.applyOps("d", [add(a, "https://dup.example/", T0)]);
    expect(await lib.parseWanted(a, 1)).toBe(true);
    expect(await lib.markParsed(a, ok())).toEqual({ ok: true });
    expect(await lib.parseWanted(a, 1)).toBe(false);
    expect(await lib.markParsed(a, ok())).toEqual({ ok: false }); // duplicate delivery → no 2nd ref_count++
    expect(await lib.markParsed(a, failed(1))).toEqual({ ok: false }); // DLQ after a committed success
    expect((await lib.getItem(a))!.parseStatus).toBe("ok");
  });

  it("item.refresh spam is coalesced into one parse job", async () => {
    const { lib } = freshLibrary();
    const a = uuidv7();
    await lib.applyOps("d", [add(a, "https://refresh.example/", T0)]);
    await lib.markParsed(a, ok());
    const r = await lib.applyOps("d", Array.from({ length: 50 }, (_, i) => refresh(a, T0 + i + 1)));
    expect(r.response.applied).toHaveLength(50);
    expect(r.parseJobs).toHaveLength(1);
  });

  it("parse budget: jobs over budget are deferred to the sweep, not dropped", async () => {
    const { lib } = freshLibrary();
    await lib.applyOps("d", [add(uuidv7(), "https://b0.example/", T0)]);
    await runInDurableObject(lib, async (inst: LibraryDO, state) => {
      storeOf(inst).setMetaNumber("parse_budget", 2);
      storeOf(inst).setMetaNumber("parse_budget_at", Date.now());
      await state.storage.deleteAlarm();
    });
    const ids = [uuidv7(), uuidv7(), uuidv7(), uuidv7(), uuidv7()];
    const r = await lib.applyOps("d", ids.map((id, i) => add(id, `https://b${i + 1}.example/`, T0)));
    expect(r.response.applied).toHaveLength(5);
    expect(r.parseJobs).toHaveLength(2);
    await runInDurableObject(lib, async (_inst: LibraryDO, state) => {
      const deferred = state.storage.sql.exec("SELECT COUNT(*) AS n FROM items WHERE parse_requested_at = 0 AND parse_status = 'pending'").one();
      expect(deferred.n).toBe(3);
      const alarm = await state.storage.getAlarm();
      expect(alarm).not.toBeNull();
      expect(alarm! - Date.now()).toBeLessThan(15 * 60 * 1000);
    });
  });

  it("a huge tag rename is split into bounded seq groups, and pull pages through all of it", async () => {
    const { lib } = freshLibrary();
    const n = MAX_SEQ_GROUP * 2 + 17;
    const ids = Array.from({ length: n }, () => uuidv7());
    await lib.applyOps("imp", ids.map((id, i) => add(id, `https://g.example/${i}`, T0, { tags: ["read later"] })));
    const before = (await lib.pull(0, 1000)) as { ok: true; data: { cursor: number } };
    await lib.applyOps("d", [rename("read later", "later", T0 + 10)]);
    const seen = new Set<string>();
    let cursor = before.data.cursor;
    for (let page = 0; page < 50; page++) {
      const r = await lib.pull(cursor, 100);
      if (!r.ok) throw new Error("resync");
      expect(r.data.items.length + r.data.tags.length).toBeLessThanOrEqual(100 + MAX_SEQ_GROUP);
      for (const it of r.data.items) {
        expect(it.tags).toEqual(["later"]);
        seen.add(it.id);
      }
      cursor = r.data.cursor;
      if (!r.data.hasMore) break;
    }
    expect(seen.size).toBe(n);
  });

  it("a stale offline tag.delete / tag.rename doesn't act on a tag created after it (order-independent)", async () => {
    for (const order of ["stale-last", "stale-first"] as const) {
      const { lib } = freshLibrary();
      const x = uuidv7();
      await lib.applyOps("b", [add(x, "https://t.example/", T0)]);
      const staleDelete = delTag("work", T0 + 100);
      const create = tagOp(x, "work", true, T0 + 200);
      if (order === "stale-last") {
        await lib.applyOps("b", [create]);
        const r = await lib.applyOps("a", [staleDelete]);
        expect(r.response.applied).toEqual([staleDelete.opId]);
      } else {
        await lib.applyOps("a", [staleDelete]).catch(() => undefined);
        await lib.applyOps("b", [create]);
      }
      expect((await lib.getItem(x))!.tags).toEqual(["work"]);
      await lib.applyOps("a", [rename("work", "old", T0 + 150)]);
      expect((await lib.getItem(x))!.tags).toEqual(["work"]);
    }
  });

  it("deleting a captured item deletes its raw HTML and private content from R2", async () => {
    const { lib, userId } = freshLibrary();
    const a = uuidv7();
    await lib.applyOps("d", [add(a, "https://priv.example/", T0)]);
    const rawKey = `raw/${userId}/${a}.html.gz`;
    await testEnv.CONTENT.put(rawKey, "x");
    const job = await lib.requestParse(a, { rawKey, force: true });
    const cid = uuidv7();
    await testEnv.CONTENT.put(`private/${userId}/${cid}/article.html`, "x");
    expect(await lib.markParsed(a, ok({ parseGen: job!.parseGen, contentId: cid, contentPrivate: true }))).toEqual({ ok: true });
    await lib.applyOps("d", [delItem(a, T0 + 5)]);
    expect(await testEnv.CONTENT.head(rawKey)).toBeNull();
    expect(await testEnv.CONTENT.head(`private/${userId}/${cid}/article.html`)).toBeNull();
  });

  it("a re-parse supersedes the previous private content and refresh drops the captured HTML", async () => {
    const { lib, userId } = freshLibrary();
    const a = uuidv7();
    await lib.applyOps("d", [add(a, "https://priv2.example/", T0)]);
    const rawKey = `raw/${userId}/${a}.html.gz`;
    await testEnv.CONTENT.put(rawKey, "x");
    const j1 = await lib.requestParse(a, { rawKey, force: true });
    const cid1 = uuidv7();
    await testEnv.CONTENT.put(`private/${userId}/${cid1}/article.html`, "x");
    await lib.markParsed(a, ok({ parseGen: j1!.parseGen, contentId: cid1, contentPrivate: true }));
    // Refresh from the web: raw capture is no longer the source.
    const r = await lib.applyOps("d", [refresh(a, T0 + 1)]);
    expect(r.parseJobs).toHaveLength(1);
    expect(await testEnv.CONTENT.head(rawKey)).toBeNull();
    await lib.markParsed(a, ok({ parseGen: r.parseJobs[0]!.parseGen }));
    expect(await testEnv.CONTENT.head(`private/${userId}/${cid1}/article.html`)).toBeNull();
  });
});
