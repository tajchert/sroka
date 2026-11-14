import { runInDurableObject } from "cloudflare:test";
import { type ParseResult, PARSER_VERSION, uuidv7 } from "@sroka/shared";
import { describe, expect, it } from "vitest";
import type { LibraryStore } from "../../src/do/store.ts";
import type { LibraryDO } from "../../src/library-do.ts";
import { migrate } from "../platform/helpers.ts";
import { T0, add, delItem, freshLibrary, testEnv } from "./helpers.ts";

const storeOf = (inst: LibraryDO) => (inst as unknown as { store: LibraryStore }).store;

const parsed = (parseGen: number, contentId: string): ParseResult => ({
  status: "ok",
  parseGen,
  contentId,
  contentPrivate: false,
  title: "T",
  excerpt: "E",
  siteName: null,
  author: null,
  lang: "en",
  wordCount: 10,
  readingMinutes: 1,
  parserVersion: PARSER_VERSION,
});

/** A promise settled from outside. */
function gate() {
  let open!: () => void;
  const opened = new Promise<void>((r) => (open = r));
  return { opened, open };
}

describe("content-refs outbox (LibraryDO → D1 content_refs)", () => {
  it("an entry changed again while its D1 batch is in flight stays pending and is flushed next, once", async () => {
    await migrate();
    const { lib, userId } = freshLibrary("outbox");
    const a = uuidv7();
    const b = uuidv7();
    const cid = uuidv7();
    await lib.applyOps("d", [add(a, "https://outbox-a.example/", T0), add(b, "https://outbox-b.example/", T0 + 1)]);
    // A references the content publicly → the ref is flushed to D1.
    expect(await lib.markParsed(a, parsed(1, cid))).toEqual({ ok: true });
    const refRows = async () =>
      (
        await testEnv.DB.prepare("SELECT content_id FROM content_refs WHERE content_id = ?1 AND user_id = ?2")
          .bind(cid, userId)
          .all()
      ).results.length;
    expect(await refRows()).toBe(1);

    await runInDurableObject(lib, async (inst: LibraryDO) => {
      const store = storeOf(inst);
      expect(store.pendingRefCount()).toBe(0);

      // Hold every D1 batch of this instance until released; record what each one carries.
      const realDb = testEnv.DB;
      const batches: { held: ReturnType<typeof gate>; started: ReturnType<typeof gate>; sql: string[] }[] = [];
      const wrapped = new Proxy(realDb, {
        get(target, prop) {
          if (prop === "batch") {
            return async (stmts: D1PreparedStatement[]) => {
              const entry = { held: gate(), started: gate(), sql: [] as string[] };
              batches.push(entry);
              // D1PreparedStatement doesn't expose its SQL; the DELETE/INSERT split is asserted through D1 state below.
              entry.sql.push(String(stmts.length));
              entry.started.open();
              await entry.held.opened;
              return realDb.batch(stmts);
            };
          }
          const v = Reflect.get(target, prop, target) as unknown;
          return typeof v === "function" ? (v as (...a: unknown[]) => unknown).bind(target) : v;
        },
      });
      const holder = inst as unknown as { env: { DB: D1Database } };
      const originalEnv = holder.env;
      holder.env = { ...originalEnv, DB: wrapped };
      try {
        // 1. A is deleted: nothing references the content any more → flush #1 computes live=false (gen 2) and
        //    is now in flight (held inside db.batch).
        const flush1 = inst.applyOps("d", [delItem(a, T0 + 10)]);
        await waitUntil(() => batches.length === 1);
        await batches[0]!.started.opened;
        const [inFlight] = store.refBatch(10);
        expect(inFlight).toMatchObject({ contentId: cid, live: false });

        // 2. While it is in flight, B starts referencing the same content publicly → entry re-marked (gen + 1).
        expect(store.markParsed(b, parsed(1, cid)).ok).toBe(true);
        const [remarked] = store.refBatch(10);
        expect(remarked).toMatchObject({ contentId: cid, live: true });
        expect(remarked!.gen).toBe(inFlight!.gen + 1);

        // 3. Flush #1 finishes: its DELETE applied, but the entry is NOT cleared (gen mismatch) …
        batches[0]!.held.open();
        await waitUntil(() => batches.length === 2);
        await batches[1]!.started.opened;
        expect(store.pendingRefCount()).toBe(1);
        expect(await refRows()).toBe(0); // older state (deleted) is what D1 has right now

        // 4. … and the same flush loop picks it up with the newer desired state (live) and applies it.
        batches[1]!.held.open();
        await flush1;
        expect(store.pendingRefCount()).toBe(0);
        expect(batches).toHaveLength(2); // exactly one batch per generation: not lost, not applied twice
        expect(batches.map((x) => x.sql[0])).toEqual(["2", "2"]); // one ref statement + one content update each
      } finally {
        holder.env = originalEnv;
      }
    });

    expect(await refRows()).toBe(1); // newer state (B references the content) won
    // Nothing left to flush: a further flush is a no-op against D1.
    expect(await runInDurableObject(lib, (inst: LibraryDO) => storeOf(inst).pendingRefCount())).toBe(0);
  });
});

/** Polls until `cond` holds (the held flush runs in the same isolate, so a few microtask/timer turns suffice). */
async function waitUntil(cond: () => boolean): Promise<void> {
  for (let i = 0; i < 200; i++) {
    if (cond()) return;
    await new Promise((r) => setTimeout(r, 5));
  }
  throw new Error("timed out waiting for condition");
}
