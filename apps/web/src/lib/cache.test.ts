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
