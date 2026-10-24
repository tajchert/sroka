import type { Item } from "@sroka/shared";
import { QueryClient } from "@tanstack/react-query";
import { describe, expect, it } from "vitest";
import { itemsKey, patchItem, placeholderItem, prependItem, removeItem, replaceItem, type ItemsData, type ListParams } from "./cache.ts";

const unread: ListParams = { state: "unread", sort: "newest" };
const archived: ListParams = { state: "archived", sort: "newest" };
const base = placeholderItem("https://example.com/a");
const a: Item = { ...base, id: "a" };

function setup() {
  const qc = new QueryClient();
  const seed = (p: ListParams, items: Item[]) =>
    qc.setQueryData<ItemsData>(itemsKey(p), { pages: [{ items, nextCursor: null }], pageParams: [undefined] });
  seed(unread, [a]);
  seed(archived, []);
  const ids = (p: ListParams) => qc.getQueryData<ItemsData>(itemsKey(p))!.pages.flatMap((pg) => pg.items.map((i) => i.id));
  return { qc, ids };
}

describe("cache helpers", () => {
  it("drops an archived item from the unread list", () => {
    const { qc, ids } = setup();
    patchItem(qc, { ...a, status: "archived" });
    expect(ids(unread)).toEqual([]);
  });

  it("optimistic add is replaced by the server item, without duplicates", () => {
    const { qc, ids } = setup();
    const temp = placeholderItem("https://example.com/new");
    prependItem(qc, temp);
    expect(ids(unread)).toEqual([temp.id, "a"]);
    expect(ids(archived)).toEqual([]);
    replaceItem(qc, temp.id, { ...a, id: "a", title: "dup" });
    expect(ids(unread)).toEqual(["a"]);
  });

  it("removes an item everywhere", () => {
    const { qc, ids } = setup();
    removeItem(qc, "a");
    expect(ids(unread)).toEqual([]);
  });
});

describe("promoteItem", () => {
  it("moves an existing item to the top and caches it", async () => {
    const { promoteItem } = await import("./cache.ts");
    const { QueryClient } = await import("@tanstack/react-query");
    const qc = new QueryClient();
    const mk = (id: string) => ({ ...placeholderItem("https://x.test/" + id), id });
    const params = { state: "unread", sort: "newest" } as const;
    qc.setQueryData(["items", params], { pageParams: [undefined], pages: [{ items: [mk("a"), mk("b")], nextCursor: null }] });
    promoteItem(qc, mk("b"));
    const d = qc.getQueryData<{ pages: { items: { id: string }[] }[] }>(["items", params])!;
    expect(d.pages[0]!.items.map((i) => i.id)).toEqual(["b", "a"]);
    expect(qc.getQueryData(["item", "b"])).toBeTruthy();
  });

  it("keeps a re-added item in filtered and oldest lists, moving only newest lists it matches", async () => {
    const { promoteItem } = await import("./cache.ts");
    const { QueryClient } = await import("@tanstack/react-query");
    const qc = new QueryClient();
    const mk = (id: string, tags: string[] = []) => ({ ...placeholderItem("https://x.test/" + id), id, tags }) as Item;
    const seed = (p: ListParams, ids: string[]) =>
      qc.setQueryData<ItemsData>(itemsKey(p), { pageParams: [undefined], pages: [{ items: ids.map((i) => mk(i)), nextCursor: null }] });
    const ids = (p: ListParams) => qc.getQueryData<ItemsData>(itemsKey(p))!.pages.flatMap((pg) => pg.items.map((i) => i.id));
    const search: ListParams = { state: "unread", sort: "newest", q: "x" };
    const oldest: ListParams = { state: "unread", sort: "oldest" };
    const tagHit: ListParams = { state: "unread", sort: "newest", tag: "t" };
    const tagMiss: ListParams = { state: "unread", sort: "newest", tag: "other" };
    seed(search, ["a", "b"]);
    seed(oldest, ["a", "b"]);
    seed(tagHit, ["a", "b"]);
    seed(tagMiss, ["a", "b"]);
    promoteItem(qc, mk("b", ["t"]));
    expect(ids(search)).toEqual(["a", "b"]);
    expect(ids(oldest)).toEqual(["a", "b"]);
    expect(ids(tagHit)).toEqual(["b", "a"]);
    expect(ids(tagMiss)).toEqual(["a", "b"]);
  });
});
