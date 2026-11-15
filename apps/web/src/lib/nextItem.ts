import type { Item } from "@sroka/shared";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "./api.ts";
import { itemsKey, type ItemsData } from "./cache.ts";
import { useHiddenIds } from "./store.tsx";

/** My List in its default order, as the library page keys it. */
const MY_LIST = { state: "unread", sort: "newest" } as const;
/** Fallback fetch: pages of this size, at most FETCH_PAGES of them, stepping over items without a readable copy. */
const FETCH_LIMIT = 20;
const FETCH_PAGES = 3;

/**
 * "Next" for the reader's finish line: the first other item of My List (newest first) that is not archived,
 * not a local placeholder or pending delete, and has a readable copy (parse status ok or partial).
 */
export function pickNext(items: readonly Item[], currentId: string, hidden: ReadonlySet<string> = new Set()): Item | null {
  return (
    items.find(
      (i) =>
        i.id !== currentId &&
        !hidden.has(i.id) &&
        !i.id.startsWith("tmp-") &&
        i.status !== "archived" &&
        (i.parseStatus === "ok" || i.parseStatus === "partial"),
    ) ?? null
  );
}

async function fetchNext(currentId: string, hidden: ReadonlySet<string>): Promise<Item | null> {
  let cursor: string | undefined;
  for (let page = 0; page < FETCH_PAGES; page++) {
    const res = await api.listItems({ ...MY_LIST, limit: FETCH_LIMIT, ...(cursor ? { cursor } : {}) });
    const found = pickNext(res.items, currentId, hidden);
    if (found || !res.nextCursor) return found;
    cursor = res.nextCursor;
  }
  return null;
}

/**
 * Resolves the next item once `enabled` (the reader prefetches when the article is nearly done). Uses the
 * warm My List cache; otherwise fetches My List pages. `ready` is false only while that fetch is running.
 */
export function useNextItem(currentId: string, enabled: boolean): { next: Item | null; ready: boolean } {
  const qc = useQueryClient();
  const hidden = useHiddenIds();
  const cached = qc.getQueryData<ItemsData>(itemsKey(MY_LIST));
  const fromCache = enabled && cached ? pickNext(cached.pages.flatMap((p) => p.items), currentId, hidden) : null;
  // Never reused across visits (gcTime 0): an item archived since would come back as "next".
  const fetched = useQuery({
    queryKey: ["reader-next", currentId],
    queryFn: () => fetchNext(currentId, hidden),
    enabled: enabled && !fromCache,
    staleTime: 0,
    gcTime: 0,
    retry: false,
  });
  if (!enabled) return { next: null, ready: false };
  if (fromCache) return { next: fromCache, ready: true };
  if (fetched.isPending) return { next: null, ready: false };
  return { next: fetched.data ?? null, ready: true };
}
