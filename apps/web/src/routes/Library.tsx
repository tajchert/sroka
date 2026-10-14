import type { ItemSort, ItemState } from "@sroka/shared";
import { useInfiniteQuery } from "@tanstack/react-query";
import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useParams, useSearchParams } from "react-router";
import { ItemRow } from "../components/ItemRow.tsx";
import { api } from "../lib/api.ts";
import { itemsKey, type ItemsData, type ListParams } from "../lib/cache.ts";
import { isTyping, useItemActions } from "../lib/hooks.ts";
import { useHiddenIds } from "../lib/store.tsx";

const TITLES: Record<ItemState, string> = { unread: "My List", archived: "Archive", favorites: "Favorites", all: "All items" };
const EMPTY: Record<ItemState, string> = {
  unread: "Nothing waiting. Paste a link above or save pages with the browser extension.",
  archived: "Nothing archived yet. Finished reading? Archive it to keep My List short.",
  favorites: "No favorites yet. Star the pieces you want to find again.",
  all: "Your library is empty. Paste a link above to save your first page.",
};
const SORTS: { value: ItemSort; label: string }[] = [
  { value: "newest", label: "Newest first" },
  { value: "oldest", label: "Oldest first" },
  { value: "shortest", label: "Shortest first" },
  { value: "longest", label: "Longest first" },
];

export default function Library({ state: baseState }: { state: ItemState }) {
  const { name } = useParams();
  const tag = name ? decodeURIComponent(name) : undefined;
  const state: ItemState = tag ? "all" : baseState;
  const [sp, setSp] = useSearchParams();
  const navigate = useNavigate();
  const actions = useItemActions();
  const hidden = useHiddenIds();

  const q = sp.get("q") ?? "";
  const sort = (sp.get("sort") as ItemSort | null) ?? "newest";
  const domain = sp.get("domain") ?? undefined;
  const params: ListParams = { state, tag, q: q || undefined, sort, domain };

  const update = (patch: Record<string, string | undefined>) => {
    const next = new URLSearchParams(sp);
    for (const [k, v] of Object.entries(patch)) (v ? next.set(k, v) : next.delete(k));
    setSp(next, { replace: true });
  };

  const query = useInfiniteQuery<ItemsData["pages"][number], Error, ItemsData, ReturnType<typeof itemsKey>, string | undefined>({
    queryKey: itemsKey(params),
    initialPageParam: undefined,
    queryFn: ({ pageParam }) => api.listItems({ ...params, cursor: pageParam }),
    getNextPageParam: (last) => last.nextCursor ?? undefined,
  });

  const items = useMemo(
    () => (query.data?.pages.flatMap((p) => p.items) ?? []).filter((i) => !hidden.has(i.id)),
    [query.data, hidden],
  );

  // search box: local state, debounced into the URL
  const [search, setSearch] = useState(q);
  const searchRef = useRef<HTMLInputElement>(null);
  useEffect(() => setSearch(q), [q]);
  useEffect(() => {
    if (search === q) return;
    const t = setTimeout(() => update({ q: search.trim() || undefined }), 300);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [search]);

  // infinite scroll
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
  }, [hasNextPage, isFetchingNextPage, fetchNextPage, items.length]);

  // keyboard: j/k move, Enter open, a archive, f favorite, / search
  const [sel, setSel] = useState(0);
  useEffect(() => setSel(0), [state, tag, q, sort, domain]);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (isTyping(e) || e.metaKey || e.ctrlKey || e.altKey) return;
      const cur = items[sel];
      const move = (n: number) => {
        const i = Math.max(0, Math.min(items.length - 1, n));
        setSel(i);
        document.querySelector(`[data-item-id="${items[i]?.id}"]`)?.scrollIntoView({ block: "nearest" });
      };
      switch (e.key) {
        case "j": move(sel + 1); break;
        case "k": move(sel - 1); break;
        case "/": e.preventDefault(); searchRef.current?.focus(); break;
        case "Enter": if (cur && !cur.id.startsWith("tmp-")) navigate(`/item/${cur.id}`); break;
        case "a": if (cur) void actions.setArchived(cur, cur.status !== "archived"); break;
        case "f": if (cur) void actions.toggleFavorite(cur); break;
        default: return;
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [items, sel, actions, navigate]);

  const [url, setUrl] = useState("");
  const [adding, setAdding] = useState(false);
  const onAdd = async (e: React.FormEvent) => {
    e.preventDefault();
    if (adding || !url.trim()) return;
    setAdding(true);
    const ok = await actions.add(url);
    setAdding(false);
    if (ok) setUrl("");
  };

  const title = tag ? `#${tag}` : TITLES[state];
  const filtered = !!(q || domain);

  return (
    <div className="mx-auto max-w-4xl px-4 py-6 sm:px-8">
      <h1 className="font-serif text-3xl font-semibold tracking-tight">{title}</h1>

      <form onSubmit={onAdd} className="mt-5 flex gap-2">
        <input className="input" type="text" inputMode="url" aria-label="Page address" placeholder="Paste a link to save" value={url} onChange={(e) => setUrl(e.target.value)} />
        <button className="btn btn-primary shrink-0" disabled={adding || !url.trim()}>
          Save
        </button>
      </form>

      <div className="mt-4 flex flex-wrap items-center gap-2">
        <input ref={searchRef} className="input max-w-xs !py-1.5 text-sm" type="search" aria-label="Search" placeholder="Search ( / )" value={search} onChange={(e) => setSearch(e.target.value)} />
        <select className="input !w-auto !py-1.5 text-sm" aria-label="Sort" value={sort} onChange={(e) => update({ sort: e.target.value === "newest" ? undefined : e.target.value })}>
          {SORTS.map((s) => (
            <option key={s.value} value={s.value}>{s.label}</option>
          ))}
        </select>
        {domain && (
          <button type="button" className="chip !py-1" onClick={() => update({ domain: undefined })}>
            {domain} ×
          </button>
        )}
      </div>

      {query.isPending ? (
        <div className="flex justify-center py-20"><span className="spinner" aria-label="Loading" /></div>
      ) : query.isError ? (
        <div className="py-16 text-center">
          <p className="text-ink2">Could not load your library.</p>
          <button className="btn mt-3" onClick={() => void query.refetch()}>Try again</button>
        </div>
      ) : items.length === 0 ? (
        <p className="py-16 text-center text-ink2">{filtered ? "Nothing matches. Clear the search or filter." : tag ? "No items with this tag." : EMPTY[state]}</p>
      ) : (
        <ul className="mt-4">
          {items.map((it, i) => (
            <ItemRow key={it.id} item={it} selected={i === sel} onDomain={(d) => update({ domain: d })} onTag={(t) => navigate(`/tag/${encodeURIComponent(t)}`)} />
          ))}
        </ul>
      )}
      <div ref={sentinel} className="h-10" />
      {isFetchingNextPage && <div className="flex justify-center pb-8"><span className="spinner" aria-label="Loading more" /></div>}
    </div>
  );
}
