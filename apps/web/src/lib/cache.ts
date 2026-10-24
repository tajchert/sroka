/** Helpers to keep TanStack Query item lists consistent after mutations. */
import type { InfiniteData, QueryClient } from "@tanstack/react-query";
import type { Item, ItemSort, ItemState, ListItemsResponse } from "@sroka/shared";

export interface ListParams {
  state: ItemState;
  tag?: string;
  q?: string;
  sort: ItemSort;
  domain?: string;
}
export type ItemsData = InfiniteData<ListItemsResponse, string | undefined>;

export const itemsKey = (p: ListParams) => ["items", p] as const;

export function matchesState(item: Item, state: ItemState): boolean {
  if (state === "all") return true;
  if (state === "favorites") return item.isFavorite;
  return item.status === state;
}

function mapPages(data: ItemsData, fn: (items: Item[]) => Item[]): ItemsData {
  return { ...data, pages: data.pages.map((p) => ({ ...p, items: fn(p.items) })) };
}

/** Replace the item everywhere it is cached; drop it from lists it no longer belongs in. */
export function patchItem(qc: QueryClient, item: Item): void {
  qc.setQueryData(["item", item.id], item);
  for (const [key, data] of qc.getQueriesData<ItemsData>({ queryKey: ["items"] })) {
    if (!data) continue;
    const params = key[1] as ListParams;
    qc.setQueryData<ItemsData>(
      key,
      mapPages(data, (items) =>
        items.flatMap((i) => (i.id !== item.id ? [i] : matchesState(item, params.state) ? [item] : [])),
      ),
    );
  }
}

export function removeItem(qc: QueryClient, id: string): void {
  qc.removeQueries({ queryKey: ["item", id] });
  for (const [key, data] of qc.getQueriesData<ItemsData>({ queryKey: ["items"] })) {
    if (data) qc.setQueryData<ItemsData>(key, mapPages(data, (items) => items.filter((i) => i.id !== id)));
  }
}

/** Optimistically prepend an item to lists where a freshly saved item would show (no filters, newest sort). */
export function prependItem(qc: QueryClient, item: Item): void {
  for (const [key, data] of qc.getQueriesData<ItemsData>({ queryKey: ["items"] })) {
    if (!data) continue;
    const p = key[1] as ListParams;
    if (p.q || p.tag || p.domain || p.sort !== "newest" || !matchesState(item, p.state)) continue;
    if (data.pages.some((pg) => pg.items.some((i) => i.id === item.id))) continue;
    const [first, ...rest] = data.pages;
    if (!first) continue;
    qc.setQueryData<ItemsData>(key, { ...data, pages: [{ ...first, items: [item, ...first.items] }, ...rest] });
  }
}

/** Swap an optimistic placeholder for the server item (dedupe if the server item is already listed). */
export function replaceItem(qc: QueryClient, tempId: string, item: Item): void {
  for (const [key, data] of qc.getQueriesData<ItemsData>({ queryKey: ["items"] })) {
    if (!data) continue;
    const has = data.pages.some((pg) => pg.items.some((i) => i.id === item.id));
    qc.setQueryData<ItemsData>(
      key,
      mapPages(data, (items) =>
        items.flatMap((i) => (i.id === tempId ? (has ? [] : [item]) : i.id === item.id && has ? [item] : [i])),
      ),
    );
  }
  qc.setQueryData(["item", item.id], item);
}

export function placeholderItem(url: string): Item {
  return {
    id: `tmp-${Date.now()}`,
    url,
    canonicalUrl: url,
    title: null,
    excerpt: null,
    siteName: null,
    author: null,
    lang: null,
    leadImageUrl: null,
    leadImageKey: null,
    wordCount: null,
    readingMinutes: null,
    contentId: null,
    contentPrivate: false,
    parseStatus: "pending",
    parseError: null,
    status: "unread",
    isFavorite: false,
    progress: 0,
    progressAnchor: null,
    savedAt: Date.now(),
    archivedAt: null,
    lastReadAt: null,
    source: "web",
    kind: "article",
    fileName: null,
    fileSize: null,
    tags: [],
    seq: 0,
  };
}

/** Put an uploaded item at the top of the lists it belongs in (re-added duplicates move up). */
export function promoteItem(qc: QueryClient, item: Item): void {
  for (const [key, data] of qc.getQueriesData<ItemsData>({ queryKey: ["items"] })) {
    if (data) qc.setQueryData<ItemsData>(key, mapPages(data, (items) => items.filter((i) => i.id !== item.id)));
  }
  prependItem(qc, item);
  qc.setQueryData(["item", item.id], item);
}
