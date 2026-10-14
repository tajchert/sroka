import { runInDurableObject } from "cloudflare:test";
import { type ListItemsQuery, type ParseJob, uuidv7 } from "@sroka/shared";
import { describe, expect, it } from "vitest";
import { normalizeDomainFilter } from "../../src/do/fts.ts";
import type { LibraryStore } from "../../src/do/store.ts";
import type { LibraryDO } from "../../src/library-do.ts";
import { T0, add, delItem, delTag, freshLibrary, rename, tagOp } from "./helpers.ts";

const q = (over: Partial<ListItemsQuery> = {}): ListItemsQuery => ({ state: "all", sort: "newest", limit: 30, ...over });
const DAY = 86_400_000;
const storeOf = (inst: LibraryDO) => (inst as unknown as { store: LibraryStore }).store;

describe("review fixes", () => {
  it("stale tag op redirected through a rename to a deleted tag never crashes the push", async () => {
    const { lib } = freshLibrary();
    const x = uuidv7();
    await lib.applyOps("d1", [add(x, "https://r.example/", T0), tagOp(x, "a", true, T0 + 1)]);
    await lib.applyOps("d1", [rename("a", "b", T0 + 10)]);
    await lib.applyOps("d2", [delTag("b", T0 + 5)]); // skewed clock
    await lib.applyOps("d1", [tagOp(x, "a", true, T0 + 20)]); // live "a" again
    const stale = tagOp(x, "a", true, T0 + 7);
    const after = tagOp(x, "z", true, T0 + 30);
    const r = await lib.applyOps("d3", [stale, after]);
    expect(r.response.rejected).toEqual([]);
    expect(r.response.applied).toEqual([stale.opId, after.opId]);
    expect((await lib.getItem(x))!.tags.sort()).toEqual(["a", "z"]);
    expect((await lib.listTags()).map((t) => t.name).sort()).toEqual(["a", "z"]);
  });

  it("an unexpected error on one op is rejected, other ops still apply", async () => {
    const { lib } = freshLibrary();
    const x = uuidv7();
    await lib.applyOps("d", [add(x, "https://e.example/", T0)]);
    await runInDurableObject(lib, (inst: LibraryDO, state) => {
      state.storage.sql.exec("CREATE TRIGGER boom BEFORE UPDATE OF user_title ON items BEGIN SELECT RAISE(ABORT, 'boom'); END");
      const bad = { opId: uuidv7(), at: T0 + 1, type: "item.setTitle" as const, itemId: x, title: "T" };
      const good = { opId: uuidv7(), at: T0 + 2, type: "item.setFavorite" as const, itemId: x, value: true };
      const r = storeOf(inst).applyOps("d", [bad, good], [null, null]);
      expect(r.response.rejected).toEqual([{ opId: bad.opId, reason: "invalid_op" }]);
      expect(r.response.applied).toEqual([good.opId]);
      state.storage.sql.exec("DROP TRIGGER boom");
    });
  });

  it("purges tombstones by server time, not the client's (skewed) delete stamp", async () => {
    const { lib } = freshLibrary();
    const a = uuidv7();
    const old = Date.now() - 365 * DAY; // long-offline device
    await lib.applyOps("d", [add(a, "https://old.example/", old), delItem(a, old + 1)]);
    await runInDurableObject(lib, (inst: LibraryDO, state) => {
      storeOf(inst).prune(Date.now());
      expect(state.storage.sql.exec("SELECT COUNT(*) AS n FROM items").one().n).toBe(1);
      expect(storeOf(inst).getMeta("tombstone_horizon")).toBe(0);
      storeOf(inst).prune(Date.now() + 181 * DAY);
      expect(state.storage.sql.exec("SELECT COUNT(*) AS n FROM items").one().n).toBe(0);
      expect(storeOf(inst).getMeta("tombstone_horizon")).toBeGreaterThan(0);
    });
    expect((await lib.pull(1, 10)).ok).toBe(false);
  });

  it("re-add under a client id whose alias target was purged creates a reachable item", async () => {
    const { lib } = freshLibrary();
    const target = uuidv7();
    const client = uuidv7();
    await lib.applyOps("d1", [add(target, "https://alias.example/", T0)]);
    const r = await lib.applyOps("d2", [add(client, "https://alias.example/", T0 + 1)]);
    expect(r.response.aliases[client]).toBe(target);
    await lib.applyOps("d1", [delItem(target, T0 + 2)]);
    await runInDurableObject(lib, (_inst: LibraryDO, state) => {
      // Simulate a purged tombstone whose alias row survived (data written before prune dropped aliases).
      state.storage.sql.exec("DELETE FROM items WHERE id = ?", target);
      expect(state.storage.sql.exec("SELECT COUNT(*) AS n FROM item_aliases").one().n).toBe(1);
    });
    const again = await lib.applyOps("d2", [add(client, "https://alias.example/", T0 + 3)]);
    expect(again.response.applied).toHaveLength(1);
    expect(again.response.aliases[client]).toBeUndefined();
    expect((await lib.getItem(client))!.id).toBe(client);
  });

  it("prune drops aliases whose target was purged", async () => {
    const { lib } = freshLibrary();
    const target = uuidv7();
    const client = uuidv7();
    await lib.applyOps("d1", [add(target, "https://p.example/", T0)]);
    await lib.applyOps("d2", [add(client, "https://p.example/", T0 + 1)]);
    await lib.applyOps("d1", [delItem(target, T0 + 2)]);
    await runInDurableObject(lib, (inst: LibraryDO, state) => {
      storeOf(inst).prune(Date.now() + 181 * DAY);
      expect(state.storage.sql.exec("SELECT COUNT(*) AS n FROM item_aliases").one().n).toBe(0);
    });
  });

  it("stuck-pending sweep re-issues parse jobs (lost queue send)", async () => {
    const { lib, userId } = freshLibrary();
    const a = uuidv7();
    const b = uuidv7();
    await lib.applyOps("d", [add(a, "https://s1.example/", T0), add(b, "https://s2.example/", T0)]);
    await lib.requestParse(b, { rawKey: `raw/${userId}/${b}.html.gz` });
    await runInDurableObject(lib, (inst: LibraryDO) => {
      const s = storeOf(inst);
      expect(s.requeueStalePending(Date.now() - 60_000, 100)).toEqual([]); // fresh → untouched
      const jobs: ParseJob[] = s.requeueStalePending(Date.now() + 1, 100);
      expect(jobs.map((j) => j.itemId).sort()).toEqual([a, b].sort());
      // Same gen (no bump): a still-queued original job stays valid instead of being invalidated.
      expect(jobs.find((j) => j.itemId === b)).toMatchObject({ rawKey: `raw/${userId}/${b}.html.gz`, parseGen: 2 });
      expect(jobs.find((j) => j.itemId === a)).toMatchObject({ parseGen: 1 });
      // Re-sent → fresh again.
      expect(s.requeueStalePending(Date.now() - 60_000, 100)).toEqual([]);
      expect(jobs.find((j) => j.itemId === a)!.rawKey).toBeUndefined();
    });
  });

  it("PATCH is all-or-nothing", async () => {
    const { lib } = freshLibrary();
    const x = uuidv7();
    await lib.applyOps("d", [add(x, "https://patch.example/", T0)]);
    await lib.applyOps("d", Array.from({ length: 100 }, (_, i) => tagOp(x, `t${i}`, true, T0 + 1)));
    const before = (await lib.getItem(x))!;
    expect(before.tags).toHaveLength(100);
    // Adding a 101st tag is rejected → the status change must roll back too.
    const res = await lib.patchItem("rest", x, { status: "archived", tags: [...before.tags, "extra"] }, Date.now());
    expect(res.response.applied).toEqual([]);
    expect(res.response.rejected.map((r) => r.reason)).toContain("too_many_tags");
    const after = (await lib.getItem(x))!;
    expect(after.status).toBe("unread");
    expect(after.seq).toBe(before.seq);
  });

  it("domain filter matches IDN hosts stored in punycode", async () => {
    const puny = new URL("http://żółw.pl").hostname;
    expect(normalizeDomainFilter("Żółw.PL")).toBe(puny);
    expect(normalizeDomainFilter("https://www.żółw.pl/x")).toBe(puny);
    const { lib } = freshLibrary();
    const id = uuidv7();
    await lib.applyOps("d", [add(id, "https://www.żółw.pl/artykul", T0)]);
    const r = await lib.listItems(q({ domain: "żółw.pl" }));
    expect(r.ok && r.items.map((i) => i.id)).toEqual([id]);
  });
});
