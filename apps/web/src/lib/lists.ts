import type { Item } from "@sroka/shared";
import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import { useEffect, useMemo, useRef } from "react";
import { api } from "./api.ts";
import { itemsKey, type ItemsData, type ListParams } from "./cache.ts";
import { useHiddenIds } from "./store.tsx";

/** One paged item list (minus items hidden by a pending delete). */
export function useItemList(params: ListParams, enabled = true) {
  const hidden = useHiddenIds();
  const query = useInfiniteQuery<ItemsData["pages"][number], Error, ItemsData, ReturnType<typeof itemsKey>, string | undefined>({
    queryKey: itemsKey(params),
    initialPageParam: undefined,
    queryFn: ({ pageParam }) => api.listItems({ ...params, cursor: pageParam }),
    getNextPageParam: (last) => last.nextCursor ?? undefined,
    enabled,
  });
  const items: Item[] = useMemo(
    () => (query.data?.pages.flatMap((p) => p.items) ?? []).filter((i) => !hidden.has(i.id)),
    [query.data, hidden],
  );
  return { query, items };
}

/** Loads the next page when the returned sentinel element scrolls near the viewport. */
export function useInfiniteScroll(query: ReturnType<typeof useItemList>["query"], dep: unknown) {
  const sentinel = useRef<HTMLDivElement>(null);
  const { hasNextPage, isFetchingNextPage, fetchNextPage } = query;
  useEffect(() => {
    const el = sentinel.current;
    if (!el || !hasNextPage) return;
    const io = new IntersectionObserver(
      (es) => {
        if (es[0]?.isIntersecting && !isFetchingNextPage) void fetchNextPage();
      },
      { root: document.getElementById("scroll-root"), rootMargin: "400px" },
    );
    io.observe(el);
    return () => io.disconnect();
  }, [hasNextPage, isFetchingNextPage, fetchNextPage, dep]);
  return sentinel;
}

/** True when the old first row is still in the list but no longer first: new rows were inserted above it. */
export function insertedAbove(previousFirstId: string | undefined, ids: readonly string[]): boolean {
  return previousFirstId !== undefined && ids.indexOf(previousFirstId) > 0;
}

/**
 * In a newest-first list, scrolls back to the top when items arrive above the first row (a save, or a refetch
 * picking up saves from another device) so the new rows are visible. Deletes, sort/filter changes and first
 * loads don't move the page; `listKey` identifies the list so switching lists never counts as an insert.
 */
export function useFollowNewItems(items: readonly Item[], listKey: string, enabled: boolean) {
  const seen = useRef<{ key: string; first: string | undefined }>({ key: listKey, first: undefined });
  const first = items[0]?.id;
  useEffect(() => {
    const before = seen.current;
    seen.current = { key: listKey, first };
    if (!enabled || before.key !== listKey || before.first === first) return;
    if (!insertedAbove(before.first, items.map((i) => i.id))) return;
    document.getElementById("scroll-root")?.scrollTo({ top: 0, behavior: "smooth" });
  }, [items, first, listKey, enabled]);
}

/** Library stats from the signed-in session (already loaded by the shell). */
export function useStats() {
  const me = useQuery({ queryKey: ["me"], queryFn: api.meOrNull, retry: false, staleTime: 60_000 });
  return me.data?.stats;
}
