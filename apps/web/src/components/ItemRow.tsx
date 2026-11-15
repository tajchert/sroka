import { VOCAB, failureReason, type Item } from "@sroka/shared";
import { useState } from "react";
import { Link, useNavigate } from "react-router";
import { formatSize } from "../lib/pdf.ts";
import { hostOf, itemTitle, useItemActions, useParsePolling } from "../lib/hooks.ts";
import { ICONS, MenuItem, MenuLink, MenuSep, MoreMenu, Star } from "./MoreMenu.tsx";
import { CheckIcon, ErrorIcon, ExternalIcon, LockIcon, RetryIcon, WarnIcon } from "./StatusIcons.tsx";
import { TagEditor } from "./TagEditor.tsx";

/** Progress at or above this counts as finished ("Read"); below STARTED it shows as unread. */
const READ_THRESHOLD = 0.98;
const STARTED_THRESHOLD = 0.02;

export interface ItemRowProps {
  item: Item;
  /** Keyboard (j/k) cursor. A click on the row opens the item; there is no click selection. */
  selected?: boolean;
  onDomain: (domain: string) => void;
  onTag: (tag: string) => void;
}

export function ItemRow({ item, selected, onDomain, onTag }: ItemRowProps) {
  const actions = useItemActions();
  const navigate = useNavigate();
  const [editing, setEditing] = useState(false);
  useParsePolling(item);
  const temp = item.id.startsWith("tmp-");
  const archived = item.status === "archived";
  const pdf = item.kind === "pdf";
  const domain = pdf ? "PDF" : hostOf(item.canonicalUrl || item.url);
  const pct = Math.round(Math.min(1, item.progress) * 100);
  const done = item.progress >= READ_THRESHOLD;
  const started = item.progress > STARTED_THRESHOLD;
  const inProgress = started && !done;
  const status = pdf ? null : item.parseStatus;
  const paywalled = status === "partial" && item.parseError === "paywalled";
  const reason = status === "failed" ? failureReason(item.parseError) : null;

  return (
    <li
      data-item-id={item.id}
      aria-current={selected ? "true" : undefined}
      // Anywhere on the row opens the article, except its own links/buttons and a text selection.
      onClick={(e) => {
        if (temp || (e.target as HTMLElement).closest("a,button,input") || window.getSelection()?.toString()) return;
        if (e.metaKey || e.ctrlKey) window.open(`/app/item/${item.id}`, "_blank", "noopener");
        else navigate(`/item/${item.id}`);
      }}
      className={`group flex gap-3 rounded-xl ${temp ? "" : "cursor-pointer"} border-b border-rule/60 px-2 py-4 hover:bg-paper2 sm:gap-4 sm:px-3.5 ${selected ? "bg-paper2 shadow-[inset_3px_0_0_var(--wing)]" : ""}`}
    >
      <div className="relative h-16 w-24 shrink-0 overflow-hidden rounded-lg bg-paper3 sm:h-[76px] sm:w-[120px]">
        {pdf && item.leadImageUrl ? (
          <>
            <img src={item.leadImageUrl} alt="" loading="lazy" className="h-full w-full bg-white object-cover object-top" />
            <span
              data-testid="pdf-badge"
              className="absolute top-1 left-1 rounded bg-[rgb(10_11_14/.7)] px-1 py-px text-[10px] leading-tight font-semibold tracking-wide text-white"
              aria-hidden
            >
              PDF
            </span>
          </>
        ) : pdf ? (
          <div data-testid="pdf-tile" className="flex h-full w-full items-center justify-center text-lg font-semibold tracking-wide text-link" aria-hidden>
            PDF
          </div>
        ) : status === "pending" ? (
          <div data-testid="pending-tile" role="img" aria-label={VOCAB.pending} title={VOCAB.pending} className="flex h-full w-full items-center justify-center text-[22px]">
            <span className="spinner" aria-hidden />
          </div>
        ) : item.leadImageUrl ? (
          <img src={item.leadImageUrl} alt="" loading="lazy" className="h-full w-full object-cover" />
        ) : (
          <div className="flex h-full w-full items-center justify-center text-[26px] font-semibold text-link" aria-hidden>
            {domain.charAt(0).toUpperCase()}
          </div>
        )}
        {status === "failed" && (
          <span
            data-testid="status-failed"
            role="img"
            aria-label={VOCAB.failed}
            title={VOCAB.failed}
            className="absolute top-1 left-1 flex size-[22px] items-center justify-center rounded-full bg-danger text-paper shadow-sm"
          >
            <ErrorIcon size={14} />
          </span>
        )}
        {status === "partial" && (
          <span
            data-testid={paywalled ? "status-paywalled" : "status-partial"}
            role="img"
            aria-label={paywalled ? VOCAB.paywalled : VOCAB.partial}
            title={paywalled ? VOCAB.paywalled : VOCAB.partial}
            className="absolute top-1 left-1 flex size-[22px] items-center justify-center rounded-full border border-[var(--partial-rule)] bg-[var(--partial-bg)] text-[var(--partial)] shadow-sm"
          >
            {paywalled ? <LockIcon size={13} /> : <WarnIcon size={13} />}
          </span>
        )}
        {started && (
          <div className="absolute inset-x-0 bottom-0 h-1 bg-[rgb(10_11_14/.55)]" role="progressbar" aria-label="Reading progress" aria-valuenow={pct}>
            <div className={`h-full ${done ? "bg-ink3" : "bg-wing"}`} style={{ width: `${pct}%` }} />
          </div>
        )}
      </div>

      <div className="flex min-w-0 flex-1 flex-col gap-[5px]">
        <div className="flex items-start gap-3">
          <h3 className={`flex-1 line-clamp-2 min-w-0 text-[17px] leading-[1.3] font-semibold tracking-[-.005em] text-pretty ${done ? "text-ink2" : ""}`}>
            {temp ? (
              <span>{itemTitle(item)}</span>
            ) : (
              <Link to={`/item/${item.id}`} className="hover:underline">
                {itemTitle(item)}
              </Link>
            )}
          </h3>
          {status === "failed" && (
            <div className="-my-1.5 flex shrink-0 items-center pointer-coarse:-my-[9px]">
              <a
                href={item.url}
                target="_blank"
                rel="noopener noreferrer"
                title="Open original"
                aria-label="Open original"
                className="hidden size-8 items-center justify-center rounded-lg text-ink2 hover:bg-paper3 hover:text-ink sm:flex pointer-coarse:size-11"
              >
                <ExternalIcon size={18} />
              </a>
              <button
                type="button"
                title="Retry"
                aria-label="Retry"
                onClick={() => void actions.refresh(item)}
                className="flex size-8 cursor-pointer items-center justify-center rounded-lg text-ink2 hover:bg-paper3 hover:text-ink pointer-coarse:size-11"
              >
                <RetryIcon size={18} />
              </button>
            </div>
          )}
          {!temp && (
            <MoreMenu className="-mt-1 -mr-1.5 size-[30px] rounded-lg pointer-coarse:-mt-[11px] pointer-coarse:-mr-[13px] pointer-coarse:-mb-[7px] pointer-coarse:size-11">
              {(close) => (
                <>
                  {pdf ? null : (
                    <MenuLink href={item.url} icon={ICONS.external} onClick={close}>
                      Open original
                    </MenuLink>
                  )}
                  <MenuItem icon={<Star on={item.isFavorite} />} onClick={() => { close(); void actions.toggleFavorite(item); }}>
                    {item.isFavorite ? "Remove from favorites" : "Add to favorites"}
                  </MenuItem>
                  <MenuItem icon={archived ? ICONS.unarchive : ICONS.archive} onClick={() => { close(); void actions.setArchived(item, !archived); }}>
                    {archived ? "Move to My List" : "Archive"}
                  </MenuItem>
                  <MenuItem icon={ICONS.tag} onClick={() => { close(); setEditing((v) => !v); }}>
                    {editing ? "Done editing tags" : "Edit tags"}
                  </MenuItem>
                  <MenuSep />
                  <MenuItem icon={ICONS.trash} danger onClick={() => { close(); actions.remove(item); }}>
                    Delete
                  </MenuItem>
                </>
              )}
            </MoreMenu>
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
              <span>{inProgress ? `${Math.max(1, Math.round(item.readingMinutes * (1 - item.progress)))} min left` : `${item.readingMinutes} min read`}</span>
            </>
          ) : null}
          {reason && <span className="min-w-0 max-w-full truncate text-danger">{reason}</span>}
          {done ? (
            <span className="inline-flex items-center gap-1 text-xs text-ink3" title={VOCAB.read}>
              <CheckIcon size={12} />
              {VOCAB.read}
            </span>
          ) : (
            inProgress && !item.readingMinutes && <span>{pct}% read</span>
          )}
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
        {/* Two excerpt lines are always reserved (skeleton, text or nothing), so a status never changes the row's height. */}
        <div className="min-h-[42px]">
          {status === "pending" ? (
            <div data-testid="excerpt-skeleton" aria-hidden className="flex h-[42px] flex-col justify-center gap-2">
              <div className="h-3 w-3/4 animate-pulse rounded bg-paper3" />
              <div className="h-3 w-1/2 animate-pulse rounded bg-paper3" />
            </div>
          ) : (
            item.excerpt && <p className="line-clamp-2 text-sm leading-normal text-ink2/85">{item.excerpt}</p>
          )}
        </div>
      </div>
    </li>
  );
}
