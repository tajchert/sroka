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

/** Library stats from the signed-in session (already loaded by the shell). */
export function useStats() {
  const me = useQuery({ queryKey: ["me"], queryFn: api.meOrNull, retry: false, staleTime: 60_000 });
  return me.data?.stats;
}
