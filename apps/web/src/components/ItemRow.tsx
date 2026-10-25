import type { Item } from "@sroka/shared";
import { useRef, useState } from "react";
import { Link } from "react-router";
import { formatSize } from "../lib/pdf.ts";
import { hostOf, itemTitle, useItemActions, useParsePolling } from "../lib/hooks.ts";
import { TagEditor } from "./TagEditor.tsx";

export interface ItemRowProps {
  item: Item;
  selected?: boolean;
  onSelect?: () => void;
  onDomain: (domain: string) => void;
  onTag: (tag: string) => void;
}

export function ItemRow({ item, selected, onSelect, onDomain, onTag }: ItemRowProps) {
  const actions = useItemActions();
  const [editing, setEditing] = useState(false);
  const pointerType = useRef("");
  useParsePolling(item);
  const temp = item.id.startsWith("tmp-");
  const archived = item.status === "archived";
  const pdf = item.kind === "pdf";
  const domain = pdf ? "PDF" : hostOf(item.canonicalUrl || item.url);

  return (
    <li
      data-item-id={item.id}
      aria-current={selected ? "true" : undefined}
      // Touch taps and long presses must not highlight the row; only mouse/pen clicks select it.
      onPointerDown={(e) => { pointerType.current = e.pointerType; }}
      onClick={() => { if (pointerType.current !== "touch") onSelect?.(); }}
      className={`group flex gap-3 rounded-xl border-b border-rule/60 px-2 py-4 hover:bg-paper2 sm:gap-4 sm:px-3.5 ${selected ? "bg-paper2 shadow-[inset_3px_0_0_var(--wing)]" : ""}`}
    >
      <div className="h-16 w-24 shrink-0 overflow-hidden rounded-lg bg-paper3 sm:h-[76px] sm:w-[120px]">
        {pdf ? (
          <div className="flex h-full w-full items-center justify-center text-lg font-semibold tracking-wide text-link" aria-hidden>
            PDF
          </div>
        ) : item.leadImageUrl ? (
          <img src={item.leadImageUrl} alt="" loading="lazy" className="h-full w-full object-cover" />
        ) : (
          <div className="flex h-full w-full items-center justify-center text-[26px] font-semibold text-link" aria-hidden>
            {domain.charAt(0).toUpperCase()}
          </div>
        )}
      </div>

      <div className="flex min-w-0 flex-1 flex-col gap-[5px]">
        <div className="flex items-start gap-3">
          <h3 className="flex-1 text-[17px] leading-[1.3] font-semibold tracking-[-.005em] text-pretty">
            {temp ? (
              <span>{itemTitle(item)}</span>
            ) : (
              <Link to={`/item/${item.id}`} className="hover:underline">
                {itemTitle(item)}
              </Link>
            )}
          </h3>
          {!temp && (
            <div className="-mt-1 -mr-1.5 flex shrink-0 gap-0.5" onClick={(e) => e.stopPropagation()}>
              <span className="hidden gap-0.5 opacity-0 transition-opacity group-focus-within:opacity-100 group-hover:opacity-100 sm:flex">
                <IconBtn label={editing ? "Done editing tags" : "Edit tags"} on={editing} onClick={() => setEditing((v) => !v)}>
                  <path d="M9 4L7 20M17 4l-2 16M4 9h16M3.5 15h16" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
                </IconBtn>
                <IconBtn label="Delete" onClick={() => actions.remove(item)}>
                  <path d="M4.5 7h15M9.5 7V4.5h5V7M6.5 7l1 13h9l1-13M10 11v5M14 11v5" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
                </IconBtn>
              </span>
              <IconBtn label={item.isFavorite ? "Remove from favorites" : "Add to favorites"} on={item.isFavorite} onClick={() => void actions.toggleFavorite(item)}>
                <polygon
                  points="12,2.8 14.8,8.9 21.4,9.6 16.5,14.1 17.9,20.6 12,17.3 6.1,20.6 7.5,14.1 2.6,9.6 9.2,8.9"
                  fill={item.isFavorite ? "#f2c84b" : "none"}
                  stroke={item.isFavorite ? "#c99a1e" : "currentColor"}
                  strokeWidth="1.8"
                  strokeLinejoin="round"
                />
              </IconBtn>
              <IconBtn label={archived ? "Move to My List" : "Archive"} onClick={() => void actions.setArchived(item, !archived)}>
                {archived ? (
                  <path d="M3.5 5h17v4h-17z M5 9v10h14V9 M12 17v-5M9.5 14.5L12 12l2.5 2.5" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round" strokeLinecap="round" />
                ) : (
                  <path d="M3.5 5h17v4h-17z M5 9v10h14V9 M10 13h4" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round" strokeLinecap="round" />
                )}
              </IconBtn>
            </div>
          )}
        </div>
        <div className="flex flex-wrap items-center gap-x-2 gap-y-1 text-[13px] text-ink2" onClick={(e) => e.stopPropagation()}>
          {pdf ? (
            <span>PDF{item.fileSize ? ` · ${formatSize(item.fileSize)}` : ""}</span>
          ) : (
            <button type="button" className="cursor-pointer hover:text-ink hover:underline" onClick={() => onDomain(domain)} title={`Show only ${domain}`}>
              {domain}
            </button>
          )}
          {item.readingMinutes ? (
            <>
              <span aria-hidden className="text-rule2">·</span>
              <span>{item.readingMinutes} min read</span>
            </>
          ) : null}
          {item.parseStatus === "pending" && !pdf && (
            <span className="inline-flex items-center gap-1.5">
              <span className="spinner" aria-hidden /> Fetching
            </span>
          )}
          {item.parseStatus === "failed" && !pdf && (
            <span className="rounded-full border border-[#c2362f]/50 px-2 text-xs text-[#c2362f]" title={item.parseError ?? undefined}>
              Could not parse
            </span>
          )}
          {item.parseStatus === "partial" && !pdf && (
            <span
              className="inline-flex items-center gap-[5px] rounded-full border border-[var(--partial-rule)] bg-[var(--partial-bg)] px-2 text-xs text-[var(--partial)]"
              title={item.parseError === "paywalled" ? "Subscriber-only article: save it with the extension while signed in" : undefined}
            >
              <span aria-hidden className="size-[5px] rounded-full bg-beak" />
              {item.parseError === "paywalled" ? "Preview only" : "Partial"}
            </span>
          )}
          {item.progress > 0.02 && item.progress < 0.98 && <span>{Math.round(item.progress * 100)}% read</span>}
          {!editing &&
            item.tags.map((t) => (
              <button key={t} type="button" className="chip" onClick={() => onTag(t)}>
                {t}
              </button>
            ))}
        </div>
        {editing && (
          <div onClick={(e) => e.stopPropagation()}>
            <TagEditor tags={item.tags} onChange={(tags) => void actions.setTags(item, tags)} />
          </div>
        )}
        {item.excerpt && (pdf || item.parseStatus !== "pending") && <p className="line-clamp-2 text-sm leading-normal text-ink2/85">{item.excerpt}</p>}
      </div>
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
      className={`flex size-[30px] cursor-pointer items-center justify-center rounded-lg hover:bg-paper3 hover:text-ink ${on ? "text-ink" : "text-ink3"}`}
    >
      <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden>
        {children}
      </svg>
    </button>
  );
}
