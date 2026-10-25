import type { ItemState } from "@sroka/shared";
import { useQuery } from "@tanstack/react-query";
import { useNavigate, useParams, useSearchParams } from "react-router";
import { Adder } from "../components/Adder.tsx";
import { ItemRow } from "../components/ItemRow.tsx";
import { ListHeader, articles } from "../components/ListHeader.tsx";
import { api } from "../lib/api.ts";
import type { ListParams } from "../lib/cache.ts";
import { useListKeyboard } from "../lib/hooks.ts";
import { useInfiniteScroll, useItemList, useStats } from "../lib/lists.ts";
import { sortOptions, useListSort, type SortList } from "../lib/sort.ts";

const TITLES: Record<ItemState, string> = { unread: "My List", archived: "Archive", favorites: "Favorites", all: "All items" };
const EMPTY: Record<ItemState, [string, string]> = {
  unread: ["Nothing saved yet", "Tap Add to save a link, drop a PDF, or use the browser extension."],
  archived: ["Archive is empty", "Archived articles land here once you’re done reading."],
  favorites: ["No favorites yet", "Star an article to keep it here."],
  all: ["Your library is empty", "Tap Add to save your first page."],
};

export default function Library({ state: baseState }: { state: ItemState }) {
  const { name } = useParams();
  const tag = name || undefined;
  const state: ItemState = tag ? "all" : baseState;
  const list: SortList = tag ? "tag" : state;
  const [sp, setSp] = useSearchParams();
  const navigate = useNavigate();
  const stats = useStats();
  const tags = useQuery({ queryKey: ["tags"], queryFn: api.listTags, staleTime: 30_000 });
  const [sort, setSort] = useListSort(list);

  const domain = sp.get("domain") ?? undefined;
  const params: ListParams = { state, tag, sort, domain };
  const setDomain = (d: string | undefined) => {
    const next = new URLSearchParams(sp);
    if (d) next.set("domain", d);
    else next.delete("domain");
    setSp(next, { replace: true });
  };

  const { query, items } = useItemList(params);
  const sentinel = useInfiniteScroll(query, items.length);
  const [sel, setSel] = useListKeyboard(items, `${state}|${tag}|${sort}|${domain}`);

  const title = tag ? `#${tag}` : TITLES[state];
  const total = domain
    ? undefined
    : tag
      ? tags.data?.find((t) => t.name.toLowerCase() === tag.toLowerCase())?.count
      : stats && { unread: stats.unread, archived: stats.archived, favorites: stats.favorites, all: stats.unread + stats.archived }[state];
  const [emptyTitle, emptySub] = domain ? ["Nothing from this site here", "Clear the site filter to see everything."] : tag ? ["No items with this tag", "Tag an article to see it here."] : EMPTY[state];

  return (
    <div className="mx-auto flex max-w-[860px] flex-col gap-5 px-4 pt-6 pb-28 sm:px-10 sm:pt-9">
      <ListHeader title={title} countLabel={total !== undefined ? articles(total) : undefined} sort={sort} options={sortOptions(list)} onSort={setSort} />
      {domain && (
        <div>
          <button type="button" className="chip !py-1" onClick={() => setDomain(undefined)} aria-label={`Clear site filter ${domain}`}>
            {domain} ×
          </button>
        </div>
      )}
      <Adder />

      {query.isPending ? (
        <div className="flex justify-center py-20"><span className="spinner" aria-label="Loading" /></div>
      ) : query.isError ? (
        <div className="py-16 text-center">
          <p className="text-ink2">Could not load your library.</p>
          <button className="btn mt-3" onClick={() => void query.refetch()}>Try again</button>
        </div>
      ) : items.length === 0 ? (
        <div className="flex flex-col gap-1.5 py-14 text-center">
          <p className="text-[17px] font-semibold">{emptyTitle}</p>
          <p className="text-sm text-ink2">{emptySub}</p>
        </div>
      ) : (
        <ul>
          {items.map((it, i) => (
            <ItemRow
              key={it.id}
              item={it}
              selected={i === sel}
              onSelect={() => setSel(i)}
              onDomain={(d) => setDomain(d)}
              onTag={(t) => navigate(`/tag/${encodeURIComponent(t)}`)}
            />
          ))}
        </ul>
      )}
      <div ref={sentinel} className="h-10" />
      {query.isFetchingNextPage && <div className="flex justify-center pb-8"><span className="spinner" aria-label="Loading more" /></div>}
    </div>
  );
}
