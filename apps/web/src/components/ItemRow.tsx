import type { Item } from "@sroka/shared";
import { useState } from "react";
import { Link } from "react-router";
import { hostOf, itemTitle, useItemActions, useParsePolling } from "../lib/hooks.ts";
import { TagEditor } from "./TagEditor.tsx";

export interface ItemRowProps {
  item: Item;
  selected?: boolean;
  onDomain: (domain: string) => void;
  onTag: (tag: string) => void;
}

export function ItemRow({ item, selected, onDomain, onTag }: ItemRowProps) {
  const actions = useItemActions();
  const [editing, setEditing] = useState(false);
  useParsePolling(item);
  const temp = item.id.startsWith("tmp-");
  const archived = item.status === "archived";
  const domain = hostOf(item.canonicalUrl || item.url);

  return (
    <li
      data-item-id={item.id}
      aria-current={selected ? "true" : undefined}
      className={`group relative flex gap-4 border-b border-rule px-1 py-4 sm:px-3 ${selected ? "bg-paper2" : ""}`}
    >
      {selected && <span aria-hidden className="sheen-bg absolute inset-y-3 left-0 w-0.5 rounded" />}
      <div className="h-[72px] w-24 shrink-0 overflow-hidden rounded-md bg-paper2 sm:w-28">
        {item.leadImageUrl ? (
          <img src={item.leadImageUrl} alt="" loading="lazy" className="h-full w-full object-cover" />
        ) : (
          <div className="flex h-full w-full items-center justify-center font-serif text-2xl text-ink2" aria-hidden>
            {domain.charAt(0).toUpperCase()}
          </div>
        )}
      </div>

      <div className="min-w-0 flex-1">
        <h3 className="font-serif text-[1.05rem] font-semibold leading-snug">
          {temp ? (
            <span>{itemTitle(item)}</span>
          ) : (
            <Link to={`/item/${item.id}`} className="hover:underline">
              {itemTitle(item)}
            </Link>
          )}
        </h3>
        <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-[0.8rem] text-ink2">
          <button type="button" className="cursor-pointer hover:text-ink hover:underline" onClick={() => onDomain(domain)} title={`Show only ${domain}`}>
            {domain}
          </button>
          {item.readingMinutes ? <span>{item.readingMinutes} min read</span> : null}
          {item.parseStatus === "pending" && (
            <span className="inline-flex items-center gap-1.5">
              <span className="spinner" aria-hidden /> Fetching
            </span>
          )}
          {item.parseStatus === "failed" && (
            <span className="rounded border border-[#c2362f]/50 px-1.5 text-[#c2362f]" title={item.parseError ?? undefined}>
              Could not parse
            </span>
          )}
          {item.parseStatus === "partial" && <span className="rounded border border-rule px-1.5">Partial</span>}
          {item.progress > 0.02 && item.progress < 0.98 && <span>{Math.round(item.progress * 100)}% read</span>}
        </div>
        {item.excerpt && item.parseStatus !== "pending" && <p className="mt-1 line-clamp-2 text-sm text-ink2">{item.excerpt}</p>}
        <div className="mt-2 flex flex-wrap items-center gap-1.5">
          {!editing &&
            item.tags.map((t) => (
              <button key={t} type="button" className="chip" onClick={() => onTag(t)}>
                {t}
              </button>
            ))}
          {editing && (
            <div className="w-full">
              <TagEditor tags={item.tags} onChange={(tags) => void actions.setTags(item, tags)} />
            </div>
          )}
        </div>
      </div>

      {!temp && (
        <div className="flex shrink-0 flex-col items-end gap-1 text-sm opacity-100 sm:opacity-0 sm:transition-opacity sm:group-focus-within:opacity-100 sm:group-hover:opacity-100">
          <div className="flex gap-1">
            <IconBtn label={item.isFavorite ? "Remove from favorites" : "Add to favorites"} on={item.isFavorite} onClick={() => void actions.toggleFavorite(item)}>
              {item.isFavorite ? "★" : "☆"}
            </IconBtn>
            <IconBtn label={archived ? "Move to My List" : "Archive"} onClick={() => void actions.setArchived(item, !archived)}>
              {archived ? "↩" : "✓"}
            </IconBtn>
          </div>
          <div className="flex gap-1">
            <IconBtn label={editing ? "Done editing tags" : "Edit tags"} on={editing} onClick={() => setEditing((v) => !v)}>
              #
            </IconBtn>
            <IconBtn label="Delete" onClick={() => actions.remove(item)}>
              🗑
            </IconBtn>
          </div>
        </div>
      )}
    </li>
  );
}

function IconBtn({ label, onClick, on, children }: { label: string; onClick: () => void; on?: boolean; children: React.ReactNode }) {
  return (
    <button
      type="button"
      title={label}
      aria-label={label}
      aria-pressed={on}
      onClick={onClick}
      className={`flex size-8 cursor-pointer items-center justify-center rounded-full border text-base transition-colors hover:border-ink2 ${on ? "border-wing text-wing" : "border-rule text-ink2"}`}
    >
      {children}
    </button>
  );
}
