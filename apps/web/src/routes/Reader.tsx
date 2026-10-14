import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate, useParams } from "react-router";
import { patchItem } from "../lib/cache.ts";
import { TagEditor } from "../components/TagEditor.tsx";
import { ApiRequestError, api } from "../lib/api.ts";
import { hostOf, isTyping, itemTitle, useItemActions, useParsePolling } from "../lib/hooks.ts";
import {
  DEFAULT_READER_SETTINGS,
  buildSrcdoc,
  loadReaderSettings,
  readerVars,
  saveReaderSettings,
  type ReaderSettings,
} from "../lib/reader.ts";

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

  const contentId = item?.contentId;
  const contentQ = useQuery({
    queryKey: ["content", id, contentId],
    queryFn: () => api.getContent(id),
    enabled: !!contentId,
    staleTime: 6 * 3600_000,
    retry: false,
  });
  const articleQ = useQuery({
    queryKey: ["article", contentQ.data?.articleUrl],
    queryFn: () => api.fetchArticle(contentQ.data!.articleUrl),
    enabled: !!contentQ.data,
    staleTime: Infinity,
    retry: 1,
  });

  // The srcdoc is built once per article; settings changes are pushed with postMessage (no reload, no lost scroll).
  const settingsRef = useRef(settings);
  settingsRef.current = settings;
  const startAnchor = useRef<number | null>(null);
  if (item && !itemQ.isFetching && startAnchor.current === null && item.progressAnchor !== null) startAnchor.current = item.progressAnchor;
  const srcdoc = useMemo(
    () =>
      articleQ.data && contentQ.data
        ? buildSrcdoc({ html: articleQ.data, baseUrl: contentQ.data.baseUrl, settings: settingsRef.current, prefersDark: prefersDark() })
        : null,
    [articleQ.data, contentQ.data],
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
        pushSettings(settingsRef.current);
        if (startAnchor.current !== null) {
          iframeRef.current?.contentWindow?.postMessage({ type: "sroka:scrollToAnchor", anchor: startAnchor.current }, "*");
        }
      } else if (d.type === "sroka:metrics" && typeof d.progress === "number") {
        const anchor = typeof d.anchor === "number" ? d.anchor : null;
        pendingProgress.current = { progress: Math.min(1, Math.max(0, d.progress)), anchor };
        flushTimer.current ??= setTimeout(flush, 3000);
      }
    };
    window.addEventListener("message", onMsg);
    return () => {
      window.removeEventListener("message", onMsg);
      flush();
    };
  }, [flush, pushSettings]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (isTyping(e) || e.metaKey || e.ctrlKey || e.altKey || !item) return;
      if (e.key === "a") void actions.setArchived(item, item.status !== "archived");
      else if (e.key === "f") void actions.toggleFavorite(item);
      else if (e.key === "Escape") navigate(-1);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [item, actions, navigate]);

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
  const waiting = item.parseStatus === "pending" && !contentId;
  const failed = !contentId && !waiting;
  const domain = hostOf(item.canonicalUrl || item.url);

  return (
    <div className="flex h-full flex-col">
      <header className="border-b border-rule px-4 py-3 sm:px-8">
        <div className="mx-auto flex max-w-4xl flex-col gap-2">
          <div className="flex items-start justify-between gap-4">
            <div className="min-w-0">
              <Link to={archived ? "/archive" : "/"} className="text-xs text-ink2 hover:text-ink hover:underline">
                Back to {archived ? "Archive" : "My List"}
              </Link>
              <h1 className="font-serif text-xl font-semibold leading-snug sm:text-2xl">{itemTitle(item)}</h1>
              <p className="mt-0.5 text-sm text-ink2">
                {[item.siteName ?? domain, item.author, item.readingMinutes ? `${item.readingMinutes} min read` : null].filter(Boolean).join(", ")}
              </p>
            </div>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <a className="btn" href={item.url} target="_blank" rel="noopener noreferrer">Open original</a>
            <button className="btn" onClick={() => void actions.setArchived(item, !archived)}>{archived ? "Move to My List" : "Archive"}</button>
            <button className="btn" aria-pressed={item.isFavorite} onClick={() => void actions.toggleFavorite(item)}>
              {item.isFavorite ? "★ Favorite" : "☆ Favorite"}
            </button>
            <button className="btn" aria-expanded={panel === "tags"} onClick={() => setPanel(panel === "tags" ? "" : "tags")}>
              Tags{item.tags.length ? ` (${item.tags.length})` : ""}
            </button>
            <button className="btn" aria-expanded={panel === "settings"} onClick={() => setPanel(panel === "settings" ? "" : "settings")}>Reader settings</button>
            <button className="btn" onClick={() => void actions.refresh(item)}>Refresh</button>
            <button className="btn btn-danger" onClick={() => actions.remove(item, () => navigate(archived ? "/archive" : "/"))}>Delete</button>
          </div>
          {panel === "tags" && <TagEditor tags={item.tags} onChange={(tags) => void actions.setTags(item, tags)} />}
          {panel === "settings" && <SettingsPanel settings={settings} onChange={change} />}
        </div>
      </header>

      <div className="relative min-h-0 flex-1">
        {srcdoc ? (
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
            body={item.parseError ? `Reason: ${item.parseError.replaceAll("_", " ")}.` : "Open the original page instead, or try fetching it again."}
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
        {srcdoc && item.parseStatus === "pending" && (
          <div className="pointer-events-none absolute top-2 right-4 rounded-full bg-ink px-3 py-1 text-xs text-paper">Refreshing</div>
        )}
        {srcdoc && item.parseStatus === "failed" && (
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
      <h2 className="font-serif text-xl font-semibold">{title}</h2>
      {body && <p className="text-ink2">{body}</p>}
      {actions && <div className="mt-2 flex gap-2">{actions}</div>}
    </div>
  );
}

function SettingsPanel({ settings, onChange }: { settings: ReaderSettings; onChange: (p: Partial<ReaderSettings>) => void }) {
  const seg = <T extends string>(label: string, value: T, options: { v: T; l: string }[], key: keyof ReaderSettings) => (
    <fieldset className="flex flex-wrap items-center gap-2">
      <legend className="sr-only">{label}</legend>
      <span className="w-20 text-sm text-ink2" aria-hidden>{label}</span>
      {options.map((o) => (
        <button key={o.v} className="btn !py-1" aria-pressed={value === o.v} style={value === o.v ? { borderColor: "var(--wing)", color: "var(--wing)" } : undefined} onClick={() => onChange({ [key]: o.v })}>
          {o.l}
        </button>
      ))}
    </fieldset>
  );
  const range = (label: string, key: "size" | "lineHeight" | "width", min: number, max: number, step: number, fmt: (n: number) => string) => (
    <label className="flex items-center gap-2 text-sm">
      <span className="w-20 text-ink2">{label}</span>
      <input type="range" min={min} max={max} step={step} value={settings[key]} onChange={(e) => onChange({ [key]: Number(e.target.value) })} className="accent-[var(--wing)]" />
      <span className="w-14 text-ink2">{fmt(settings[key])}</span>
    </label>
  );
  return (
    <div className="flex flex-col gap-2.5 rounded-xl border border-rule bg-paper2 p-4">
      {seg("Theme", settings.theme, [{ v: "system", l: "System" }, { v: "light", l: "Light" }, { v: "dark", l: "Dark" }, { v: "sepia", l: "Sepia" }], "theme")}
      {seg("Font", settings.font, [{ v: "serif", l: "Serif" }, { v: "sans", l: "Sans" }, { v: "mono", l: "Mono" }], "font")}
      {range("Size", "size", 14, 28, 1, (n) => `${n}px`)}
      {range("Line height", "lineHeight", 1.3, 2.1, 0.05, (n) => n.toFixed(2))}
      {range("Width", "width", 480, 960, 20, (n) => `${n}px`)}
      <button className="btn w-fit !py-1" onClick={() => onChange(DEFAULT_READER_SETTINGS)}>Reset to defaults</button>
    </div>
  );
}
