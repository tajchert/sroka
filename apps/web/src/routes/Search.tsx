import type { Item, ItemState } from "@sroka/shared";
import { useState } from "react";
import { useNavigate, useSearchParams } from "react-router";
import { Adder } from "../components/Adder.tsx";
import { ItemRow } from "../components/ItemRow.tsx";
import { ListHeader } from "../components/ListHeader.tsx";
import { useListKeyboard } from "../lib/hooks.ts";
import { useItemList } from "../lib/lists.ts";
import { sortOptions, useListSort } from "../lib/sort.ts";

const GROUPS: { state: Extract<ItemState, "unread" | "archived">; label: string }[] = [
  { state: "unread", label: "My List" },
  { state: "archived", label: "Archive" },
];

/** Search across the whole library, results grouped by list (My List, Archive). */
export default function Search() {
  const [sp] = useSearchParams();
  const navigate = useNavigate();
  const q = (sp.get("q") ?? "").trim();
  const [sort, setSort] = useListSort("search");
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});

  const unread = useItemList({ state: "unread", q, sort }, !!q);
  const archived = useItemList({ state: "archived", q, sort }, !!q);
  const lists = { unread, archived };
  const groups = GROUPS.map((g) => ({ ...g, ...lists[g.state], open: !collapsed[g.state] })).filter((g) => g.items.length > 0);

  const visible: Item[] = groups.flatMap((g) => (g.open ? g.items : []));
  const [sel, setSel] = useListKeyboard(visible, `${q}|${sort}`);

  const pending = !!q && (unread.query.isPending || archived.query.isPending);
  const failed = unread.query.isError || archived.query.isError;
  const total = unread.items.length + archived.items.length;
  const more = !!(unread.query.hasNextPage || archived.query.hasNextPage);
  const countLabel = q && !pending ? `${total}${more ? "+" : ""} ${total === 1 && !more ? "result" : "results"} for “${q}”` : undefined;

  return (
    <div className="mx-auto flex max-w-[860px] flex-col gap-5 px-4 pt-6 pb-28 sm:px-10 sm:pt-9">
      <ListHeader title="Search" countLabel={countLabel} sort={sort} options={sortOptions("search")} onSort={setSort} />
      <Adder />

      {!q ? (
        <p className="py-14 text-center text-sm text-ink2">Type in the search box to search your whole library.</p>
      ) : pending ? (
        <div className="flex justify-center py-20"><span className="spinner" aria-label="Loading" /></div>
      ) : failed ? (
        <div className="py-16 text-center">
          <p className="text-ink2">Search failed.</p>
          <button
            className="btn mt-3"
            onClick={() => {
              void unread.query.refetch();
              void archived.query.refetch();
            }}
          >
            Try again
          </button>
        </div>
      ) : groups.length === 0 ? (
        <div className="flex flex-col gap-1.5 py-14 text-center">
          <p className="text-[17px] font-semibold">Nothing matches “{q}”</p>
          <p className="text-sm text-ink2">Try a different word or clear the search.</p>
        </div>
      ) : (
        <div className="flex flex-col gap-3.5">
          {groups.map((g) => (
            <section key={g.state} aria-label={g.label} className="flex flex-col">
              <h2>
                <button
                  type="button"
                  aria-expanded={g.open}
                  onClick={() => setCollapsed((c) => ({ ...c, [g.state]: !c[g.state] }))}
                  className="mb-1 flex w-full cursor-pointer items-center gap-2.5 border-b border-rule px-2 py-2.5 text-left hover:bg-paper2"
                >
                  <svg viewBox="0 0 24 24" width="14" height="14" aria-hidden className={`text-ink2 transition-transform duration-150 ${g.open ? "" : "-rotate-90"}`}>
                    <path d="M6 9l6 6 6-6" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
                  </svg>
                  <span className="text-xs font-semibold tracking-[.1em] uppercase">{g.label}</span>
                  <span className="rounded-full bg-paper3 px-[7px] py-px font-mono text-[11px] text-ink2">
                    {g.items.length}
                    {g.query.hasNextPage ? "+" : ""}
                  </span>
                </button>
              </h2>
              {g.open && (
                <>
                  <ul>
                    {g.items.map((it) => {
                      const i = visible.indexOf(it);
                      return (
                        <ItemRow
                          key={it.id}
                          item={it}
                          selected={i === sel}
                          onSelect={() => setSel(i)}
                          onDomain={(d) => navigate(`/all?domain=${encodeURIComponent(d)}`)}
                          onTag={(t) => navigate(`/tag/${encodeURIComponent(t)}`)}
                        />
                      );
                    })}
                  </ul>
                  {g.query.hasNextPage && (
                    <button type="button" className="btn mt-3 self-center" disabled={g.query.isFetchingNextPage} onClick={() => void g.query.fetchNextPage()}>
                      {g.query.isFetchingNextPage ? <span className="spinner" aria-label="Loading more" /> : `More in ${g.label}`}
                    </button>
                  )}
                </>
              )}
            </section>
          ))}
        </div>
      )}
    </div>
  );
}
