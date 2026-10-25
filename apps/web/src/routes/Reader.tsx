import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate, useParams } from "react-router";
import { patchItem } from "../lib/cache.ts";
import { PdfViewer, usePdfBlob } from "../components/PdfViewer.tsx";
import { ICONS, MenuItem, MenuLink, MenuSep, MoreMenu, Star } from "../components/MoreMenu.tsx";
import { TagEditor } from "../components/TagEditor.tsx";
import { ApiRequestError, api } from "../lib/api.ts";
import { useToasts } from "../lib/store.tsx";
import { useScreenWakeLock } from "../lib/wakeLock.ts";
import { isTyping, itemTitle, useItemActions, useParsePolling } from "../lib/hooks.ts";
import {
  DEFAULT_READER_SETTINGS,
  buildSrcdoc,
  loadReaderSettings,
  readerVars,
  saveReaderSettings,
  type ReaderSettings,
} from "../lib/reader.ts";

/** Positions below this open as if new: no "Resumed" toast. */
const RESUME_THRESHOLD = 0.02;

const prefersDark = () => typeof matchMedia === "function" && matchMedia("(prefers-color-scheme: dark)").matches;

export default function Reader() {
  const { id = "" } = useParams();
  const navigate = useNavigate();
  const actions = useItemActions();
  const iframeRef = useRef<HTMLIFrameElement>(null);
  const [settings, setSettings] = useState<ReaderSettings>(() => loadReaderSettings());
  const [panel, setPanel] = useState<"" | "settings" | "tags">("");

  const itemQ = useQuery({ queryKey: ["item", id], queryFn: () => api.getItem(id), retry: false, refetchOnMount: "always" });
  const item = itemQ.data;
  const qc = useQueryClient();
  const { gaveUp } = useParsePolling(item);
  const pdfBlob = usePdfBlob(id, item?.kind === "pdf" ? item.contentId : null);

  const contentId = item?.contentId;
  const contentQ = useQuery({
    queryKey: ["content", id, contentId],
    queryFn: () => api.getContent(id),
    enabled: !!contentId && item?.kind !== "pdf",
    // Re-signing (new exp) must not rebuild an open article: that reloads the iframe and loses the position.
    staleTime: Infinity,
    refetchOnReconnect: false,
    refetchOnWindowFocus: false,
    retry: false,
  });
  // Keyed by contentId, not by the (re-signed) URL.
  const articleQ = useQuery({
    queryKey: ["article", contentId],
    queryFn: () => api.fetchArticle(contentQ.data!.articleUrl),
    enabled: !!contentQ.data && item?.kind !== "pdf",
    staleTime: Infinity,
    retry: 1,
  });

  // The srcdoc is built once per article; settings changes are pushed with postMessage (no reload, no lost scroll).
  const settingsRef = useRef(settings);
  settingsRef.current = settings;
  const startAnchor = useRef<number | null>(null);
  // The saved position this article opens at, for the "Resumed at N%" toast (null = opens at the top).
  const resumeAt = useRef<number | null>(null);
  if (item && !itemQ.isFetching && startAnchor.current === null && item.progressAnchor !== null) {
    startAnchor.current = item.progressAnchor;
    resumeAt.current = item.progress;
  }
  const { push: pushToast } = useToasts();
  const srcdoc = useMemo(
    () =>
      articleQ.data && contentQ.data
        ? buildSrcdoc({ html: articleQ.data, baseUrl: contentQ.data.baseUrl, settings: settingsRef.current, prefersDark: prefersDark() })
        : null,
    // Rebuilt per article, not per URL signature (contentQ.data is read from the render that built it).
    [articleQ.data, contentId],
  );

  const pushSettings = useCallback((s: ReaderSettings) => {
    iframeRef.current?.contentWindow?.postMessage({ type: "sroka:settings", vars: readerVars(s, prefersDark()) }, "*");
  }, []);
  const change = (patch: Partial<ReaderSettings>) => {
    const next = { ...settings, ...patch };
    setSettings(next);
    saveReaderSettings(next);
    pushSettings(next);
  };

  // The frame can report ready before the item refetch yields the saved position (cached article on SPA
  // navigation), so the position is sent on ready and again once it is known. The frame ignores it after user input.
  const frameReady = useRef(false);
  useEffect(() => { frameReady.current = false; }, [srcdoc]);
  const resume = useCallback(() => {
    if (!frameReady.current || startAnchor.current === null) return;
    iframeRef.current?.contentWindow?.postMessage({ type: "sroka:scrollToAnchor", anchor: startAnchor.current }, "*");
    // Once per article: say where it resumed and offer the top (a settings rebuild sends ready again).
    const at = resumeAt.current;
    resumeAt.current = null;
    if (at !== null && at > RESUME_THRESHOLD) {
      pushToast(
        {
          message: `Resumed at ${Math.round(at * 100)}%`,
          actionLabel: "Start over",
          onAction: () => {
            startAnchor.current = null;
            iframeRef.current?.contentWindow?.postMessage({ type: "sroka:scrollToTop" }, "*");
          },
        },
        8000,
      );
    }
  }, [pushToast]);
  const savedAnchorKnown = !!item && !itemQ.isFetching && item.progressAnchor !== null;
  useEffect(() => { if (savedAnchorKnown) resume(); }, [savedAnchorKnown, resume]);

  // Live position for the progress bar; the frame reports it every 150 ms while scrolling.
  const [liveProgress, setLiveProgress] = useState<number | null>(null);
  useEffect(() => setLiveProgress(null), [id]);
  // Keep the screen on while reading; scrolling restarts the 5-minute idle timer.
  useScreenWakeLock(true, liveProgress);

  // progress: iframe -> parent -> PATCH (throttled, flushed on leave)
  const pendingProgress = useRef<{ progress: number; anchor: number | null } | null>(null);
  const lastSent = useRef<number>(-1);
  const flushTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const flush = useCallback(() => {
    clearTimeout(flushTimer.current);
    flushTimer.current = undefined;
    const p = pendingProgress.current;
    pendingProgress.current = null;
    if (!p || Math.abs(p.progress - lastSent.current) < 0.005) return;
    lastSent.current = p.progress;
    void api.updateItem(id, { progress: p.progress, progressAnchor: p.anchor }).then((it) => patchItem(qc, it), () => undefined);
  }, [id, qc]);

  // flush on leave: keepalive fetch survives page close (sendBeacon cannot PATCH)
  useEffect(() => {
    const leave = () => {
      const p = pendingProgress.current;
      if (!p) return;
      pendingProgress.current = null;
      lastSent.current = p.progress;
      try {
        void fetch(`/v1/items/${id}`, {
          method: "PATCH",
          keepalive: true,
          credentials: "same-origin",
          headers: { "Content-Type": "application/json", "X-Sroka-Device": "web" },
          body: JSON.stringify({ progress: p.progress, progressAnchor: p.anchor }),
        }).catch(() => undefined);
      } catch {
        /* ignore */
      }
    };
    const onVis = () => { if (document.visibilityState === "hidden") leave(); };
    window.addEventListener("pagehide", leave);
    document.addEventListener("visibilitychange", onVis);
    return () => {
      window.removeEventListener("pagehide", leave);
      document.removeEventListener("visibilitychange", onVis);
    };
  }, [id]);

  useEffect(() => {
    const onMsg = (e: MessageEvent) => {
      if (e.source !== iframeRef.current?.contentWindow) return;
      const d = e.data as { type?: string; progress?: unknown; anchor?: unknown } | null;
      if (!d || typeof d !== "object") return;
      if (d.type === "sroka:ready") {
        frameReady.current = true;
        pushSettings(settingsRef.current);
        resume();
      } else if (d.type === "sroka:metrics" && typeof d.progress === "number") {
        const anchor = typeof d.anchor === "number" ? d.anchor : null;
        if (anchor !== null) startAnchor.current = anchor; // a rebuilt frame resumes here, not at the first position
        pendingProgress.current = { progress: Math.min(1, Math.max(0, d.progress)), anchor };
        setLiveProgress(pendingProgress.current.progress);
        flushTimer.current ??= setTimeout(flush, 3000);
      }
    };
    window.addEventListener("message", onMsg);
    return () => {
      window.removeEventListener("message", onMsg);
      flush();
    };
  }, [flush, pushSettings, resume]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (isTyping(e) || e.metaKey || e.ctrlKey || e.altKey || !item) return;
      if (e.key === "a") void actions.setArchived(item, item.status !== "archived");
      else if (e.key === "f") void actions.toggleFavorite(item);
      else if (e.key === "Escape") {
        if (panel) setPanel("");
        else navigate(-1);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [item, actions, navigate, panel]);

  if (itemQ.isPending) return <div className="flex justify-center py-24"><span className="spinner" aria-label="Loading" /></div>;
  if (itemQ.isError || !item) {
    const notFound = itemQ.error instanceof ApiRequestError && itemQ.error.status === 404;
    return (
      <div className="mx-auto max-w-md px-6 py-24 text-center">
        <p className="text-ink2">{notFound ? "This item no longer exists." : "Could not load this item."}</p>
        <Link to="/" className="btn mt-4">Back to My List</Link>
      </div>
    );
  }

  const archived = item.status === "archived";
  const isPdf = item.kind === "pdf";
  const waiting = item.parseStatus === "pending" && !contentId;
  const failed = !contentId && !waiting;
  const percent = Math.round((liveProgress ?? item.progress) * 100);
  const togglePanel = (p: "settings" | "tags") => setPanel(panel === p ? "" : p);
  // The title lives in the article header; the toolbar shows it once that has scrolled away (always for PDFs).
  const miniTitle = isPdf || !srcdoc || (liveProgress ?? 0) > 0.03;

  return (
    <div className="flex h-full flex-col">
      <header className="relative z-20 flex h-14 shrink-0 items-center gap-3 border-b border-rule px-2 sm:px-4">
        <Link
          to={archived ? "/archive" : "/"}
          title="Back (Esc)"
          className="flex h-9 shrink-0 items-center gap-1 rounded-[9px] pr-3 pl-1.5 text-sm text-ink2 hover:bg-paper3 hover:text-ink"
        >
          <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden>
            <path d="M15 5l-7 7 7 7" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
          <span>{archived ? "Archive" : "My List"}</span>
        </Link>
        <h1
          aria-hidden={!miniTitle}
          className={`min-w-0 flex-1 truncate text-center text-sm font-semibold transition-opacity duration-200 ${miniTitle ? "opacity-100" : "opacity-0"}`}
        >
          {itemTitle(item)}
        </h1>
        <div className="flex shrink-0 items-center gap-0.5">
          {isPdf ? (
            <ToolLink href={pdfBlob.url} label="Open in new tab" icon={ICONS.external} />
          ) : (
            <ToolLink href={item.url} label="Open original" icon={ICONS.external} />
          )}
          <ToolBtn label={item.isFavorite ? "Remove from favorites (f)" : "Add to favorites (f)"} pressed={item.isFavorite} onClick={() => void actions.toggleFavorite(item)}>
            <Star on={item.isFavorite} />
          </ToolBtn>
          <ToolBtn label="Tags" expanded={panel === "tags"} onClick={() => togglePanel("tags")}>
            {ICONS.tag}
          </ToolBtn>
          {!isPdf && (
            <button
              type="button"
              title="Reader settings"
              aria-label="Reader settings"
              aria-expanded={panel === "settings"}
              onClick={() => togglePanel("settings")}
              className={`flex size-9 cursor-pointer items-center justify-center rounded-[9px] font-serif text-[15px] font-semibold hover:bg-paper3 hover:text-ink ${panel === "settings" ? "bg-paper3 text-ink" : "text-ink2"}`}
            >
              Aa
            </button>
          )}
          <ToolBtn label={archived ? "Move to My List (a)" : "Archive (a)"} onClick={() => void actions.setArchived(item, !archived)}>
            {archived ? ICONS.unarchive : ICONS.archive}
          </ToolBtn>
          <MoreMenu className="size-9 rounded-[9px]">
            {(close) => (
              <>
                {isPdf && pdfBlob.url && (
                  <MenuLink href={pdfBlob.url} download={item.fileName ?? "document.pdf"} icon={ICONS.download} onClick={close}>
                    Download
                  </MenuLink>
                )}
                {!isPdf && (
                  <MenuItem icon={ICONS.refresh} onClick={() => { close(); void actions.refresh(item); }}>
                    Refresh content
                  </MenuItem>
                )}
                <MenuSep />
                <MenuItem icon={ICONS.trash} danger onClick={() => { close(); actions.remove(item, () => navigate(archived ? "/archive" : "/")); }}>
                  Delete
                </MenuItem>
              </>
            )}
          </MoreMenu>
        </div>
        {panel && (
          <>
            <div aria-hidden className="fixed inset-0 z-30" onClick={() => setPanel("")} />
            <div
              role="dialog"
              aria-label={panel === "tags" ? "Tags" : "Reader settings"}
              className="absolute top-[52px] right-2 z-31 flex w-[min(300px,calc(100vw-16px))] flex-col gap-3.5 rounded-xl border border-rule2 bg-paper3 p-3.5 shadow-[0_12px_34px_rgb(0_0_0/.35)] sm:right-4"
            >
              {panel === "tags" ? (
                <>
                  <PanelLabel>Tags</PanelLabel>
                  <TagEditor tags={item.tags} onChange={(tags) => void actions.setTags(item, tags)} />
                </>
              ) : (
                <SettingsPanel settings={settings} onChange={change} />
              )}
            </div>
          </>
        )}
        {!isPdf && srcdoc && (
          <div
            className="pointer-events-none absolute -bottom-px left-0 h-0.5 bg-wing transition-[width] duration-150 ease-out"
            style={{ width: `${percent}%` }}
            role="progressbar"
            aria-label="Reading progress"
            aria-valuenow={percent}
          />
        )}
      </header>

      {!isPdf && contentId && item.parseStatus === "partial" && (
        <div role="note" className="border-b border-rule bg-ink/5 px-4 py-2 text-sm sm:px-8">
          <p className="mx-auto max-w-4xl">
            {item.parseError === "paywalled" ? (
              <>
                <strong>Only a preview was saved.</strong> This article is for subscribers. To keep the full text,{" "}
                <a className="underline" href={item.url} target="_blank" rel="noopener noreferrer">open it</a> while signed in and save it
                again with the Sroka browser extension.
              </>
            ) : (
              <>
                <strong>This copy may be incomplete.</strong>{" "}
                <a className="underline" href={item.url} target="_blank" rel="noopener noreferrer">Open the original</a> to read the full page, or
                save it with the Sroka browser extension.
              </>
            )}
          </p>
        </div>
      )}
      <div className="relative min-h-0 flex-1">
        {isPdf ? (
          contentId ? (
            <PdfViewer item={item} blobUrl={pdfBlob.url} error={pdfBlob.error} onRetry={pdfBlob.retry} />
          ) : (
            <Notice title="This PDF is not available" body="The file is missing. Delete this item and add the PDF again." />
          )
        ) : srcdoc ? (
          <iframe
            ref={iframeRef}
            title={itemTitle(item)}
            sandbox="allow-scripts allow-popups allow-popups-to-escape-sandbox"
            srcDoc={srcdoc}
            className="h-full w-full border-0"
          />
        ) : waiting ? (
          <Notice busy title="Fetching this page" body={gaveUp ? "Still processing. This is taking longer than usual. Check back soon." : "Sroka is extracting the article. This usually takes a few seconds."} />
        ) : failed ? (
          <Notice
            title="This page could not be turned into an article"
            body={
              item.parseError === "bot_wall"
                ? "This site blocks automated fetching. Open it in your browser and save it again with the Sroka browser extension."
                : item.parseError
                  ? `Reason: ${item.parseError.replaceAll("_", " ")}.`
                  : "Open the original page instead, or try fetching it again."
            }
            actions={<>
              <a className="btn btn-primary" href={item.url} target="_blank" rel="noopener noreferrer">Open original</a>
              <button className="btn" onClick={() => void actions.refresh(item)}>Retry</button>
            </>}
          />
        ) : contentQ.isError || articleQ.isError ? (
          <Notice
            title="Could not load the article"
            body="The saved copy did not load. Try again, or open the original page."
            actions={<>
              <button className="btn btn-primary" onClick={() => { void contentQ.refetch(); void articleQ.refetch(); }}>Try again</button>
              <a className="btn" href={item.url} target="_blank" rel="noopener noreferrer">Open original</a>
            </>}
          />
        ) : (
          <Notice busy title="Loading article" body="" />
        )}
        {!isPdf && srcdoc && item.parseStatus === "pending" && (
          <div className="pointer-events-none absolute top-2 right-4 rounded-full bg-ink px-3 py-1 text-xs text-paper">Refreshing</div>
        )}
        {!isPdf && srcdoc && item.parseStatus === "failed" && (
          <div className="absolute top-2 right-4 rounded-full bg-ink px-3 py-1 text-xs text-paper">Refresh failed. Showing the earlier copy.</div>
        )}
      </div>
    </div>
  );
}

function Notice({ title, body, busy, actions }: { title: string; body: string; busy?: boolean; actions?: React.ReactNode }) {
  return (
    <div className="mx-auto flex max-w-md flex-col items-center gap-3 px-6 py-24 text-center">
      {busy && <span className="spinner" aria-hidden />}
      <h2 className="text-xl font-semibold">{title}</h2>
      {body && <p className="text-ink2">{body}</p>}
      {actions && <div className="mt-2 flex gap-2">{actions}</div>}
    </div>
  );
}

const toolCls = "flex size-9 cursor-pointer items-center justify-center rounded-[9px] hover:bg-paper3 hover:text-ink";

function ToolBtn({ label, onClick, pressed, expanded, children }: { label: string; onClick: () => void; pressed?: boolean; expanded?: boolean; children: React.ReactNode }) {
  return (
    <button
      type="button"
      title={label}
      aria-label={label}
      aria-pressed={pressed}
      aria-expanded={expanded}
      onClick={onClick}
      className={`${toolCls} ${expanded ? "bg-paper3 text-ink" : "text-ink2"}`}
    >
      <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden>
        {children}
      </svg>
    </button>
  );
}

function ToolLink({ href, label, icon }: { href: string | null; label: string; icon: React.ReactNode }) {
  return (
    <a
      href={href ?? undefined}
      aria-disabled={!href}
      target="_blank"
      rel="noopener noreferrer"
      title={label}
      aria-label={label}
      className={`${toolCls} text-ink2 aria-disabled:pointer-events-none aria-disabled:opacity-50`}
    >
      <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden>
        {icon}
      </svg>
    </a>
  );
}

const PanelLabel = ({ children }: { children: React.ReactNode }) => (
  <div className="text-[11px] font-medium tracking-[.1em] text-ink3 uppercase">{children}</div>
);

const WIDTHS = [
  { v: 560, l: "Narrow" },
  { v: 680, l: "Medium" },
  { v: 840, l: "Wide" },
];

function SettingsPanel({ settings, onChange }: { settings: ReaderSettings; onChange: (p: Partial<ReaderSettings>) => void }) {
  const seg = <T extends string | number>(label: string, value: T, options: { v: T; l: string; font?: string }[], key: keyof ReaderSettings) => (
    <fieldset className="flex flex-col gap-1.5">
      <legend className="contents"><PanelLabel>{label}</PanelLabel></legend>
      <div className="grid gap-1 rounded-[9px] bg-paper p-[3px]" style={{ gridTemplateColumns: `repeat(${options.length}, minmax(0, 1fr))` }}>
        {options.map((o) => (
          <button
            key={o.v}
            type="button"
            aria-pressed={value === o.v}
            onClick={() => onChange({ [key]: o.v })}
            style={o.font ? { fontFamily: o.font } : undefined}
            className={`h-8 cursor-pointer rounded-[7px] text-[13px] ${value === o.v ? "bg-paper3 text-ink shadow-[0_0_0_1px_var(--rule-2)]" : "text-ink2 hover:text-ink"}`}
          >
            {o.l}
          </button>
        ))}
      </div>
    </fieldset>
  );
  const step = (label: string, key: "size" | "lineHeight", min: number, max: number, by: number, fmt: (n: number) => string, small: string, big: string) => {
    const set = (n: number) => onChange({ [key]: Math.round(Math.min(max, Math.max(min, n)) * 100) / 100 });
    return (
      <div className="flex flex-col gap-1.5">
        <PanelLabel>{label}</PanelLabel>
        <div className="flex items-center gap-1 rounded-[9px] bg-paper p-[3px]">
          <button type="button" aria-label={`Decrease ${label.toLowerCase()}`} disabled={settings[key] <= min} onClick={() => set(settings[key] - by)} className="h-8 flex-1 cursor-pointer rounded-[7px] font-serif text-[13px] hover:bg-paper3 disabled:cursor-default disabled:opacity-40">{small}</button>
          <div className="w-12 text-center font-mono text-xs text-ink2" aria-live="polite">{fmt(settings[key])}</div>
          <button type="button" aria-label={`Increase ${label.toLowerCase()}`} disabled={settings[key] >= max} onClick={() => set(settings[key] + by)} className="h-8 flex-1 cursor-pointer rounded-[7px] font-serif text-lg hover:bg-paper3 disabled:cursor-default disabled:opacity-40">{big}</button>
        </div>
      </div>
    );
  };
  return (
    <>
      {seg("Theme", settings.theme, [{ v: "system", l: "Auto" }, { v: "light", l: "Light" }, { v: "dark", l: "Dark" }, { v: "sepia", l: "Sepia" }], "theme")}
      {seg("Typeface", settings.font, [{ v: "serif", l: "Serif", font: "var(--font-read)" }, { v: "sans", l: "Sans", font: "var(--font-ui)" }, { v: "mono", l: "Mono", font: "var(--font-mono)" }], "font")}
      {step("Size", "size", 14, 28, 1, (n) => `${n}px`, "A−", "A+")}
      {step("Line spacing", "lineHeight", 1.3, 2.1, 0.1, (n) => n.toFixed(1), "−", "+")}
      {seg("Line width", settings.width, WIDTHS, "width")}
      <button type="button" className="w-fit cursor-pointer text-xs text-link hover:underline" onClick={() => onChange(DEFAULT_READER_SETTINGS)}>
        Reset to defaults
      </button>
    </>
  );
}
