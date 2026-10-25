import { alwaysCapture, detectPaywall, LIMITS, type Item } from "@sroka/shared";
import { ApiFailure, saveItem, type SaveBody } from "./api.ts";
import { setCached } from "./badge-cache.ts";
import { ext } from "./chrome.ts";
import { enqueue } from "./queue.ts";
import { getSettings } from "./settings.ts";

export const MAX_CAPTURE_BYTES = 5 * 1024 * 1024;

export type SaveResult =
  | { ok: true; item: Item; created: boolean }
  | { ok: false; queued: boolean; reason: "signed_out" | "offline" | "error" | "unsupported"; message?: string };

export function isSavableUrl(url: string | undefined): url is string {
  return !!url && /^https?:\/\//i.test(url);
}

/**
 * Runs in the page (self-contained, passed to executeScript): the rendered DOM without what the parser never uses
 * (scripts except JSON-LD, styles, stylesheet/preload links, SVG, templates), typically 60-80% smaller.
 * Copied into an inert document so nothing in the copy loads or runs.
 * On a Reddit thread it also embeds the thread's JSON (`<script type="application/json" id="sroka-reddit-json">`,
 * fetched here: same origin, the user's session) pruned to what the extractor reads: the rendered page lazy-loads
 * comments, the JSON has the whole tree. Any failure just leaves it out.
 */
export async function pageHtmlForCapture(): Promise<string> {
  let redditJson: string | null = null;
  if (/(^|\.)reddit\.com$/i.test(location.hostname) && /^\/(r|u|user)\/[^/]+\/comments\//.test(location.pathname)) {
    const KEEP = new Set([
      "kind", "data", "children", "id", "name", "title", "author", "subreddit_name_prefixed", "score", "num_comments",
      "created_utc", "selftext_html", "body_html", "url", "permalink", "is_video", "is_self", "is_gallery", "post_hint",
      "gallery_data", "items", "media_id", "media_metadata", "s", "u", "gif", "preview", "images", "source", "replies",
      "count", "depth", "is_submitter", "stickied", "distinguished", "over_18", "spoiler", "link_flair_text",
    ]);
    // media_metadata is keyed by media id: keep every key one level below it.
    const prune = (v: unknown, keepAll = false): unknown => {
      if (Array.isArray(v)) return v.map((x) => prune(x));
      if (!v || typeof v !== "object") return v;
      const out: Record<string, unknown> = {};
      for (const [k, x] of Object.entries(v)) if (keepAll || KEEP.has(k)) out[k] = prune(x, k === "media_metadata");
      return out;
    };
    try {
      const isComment = /\/comments\/[^/]+\/[^/]*\/[^/]+\/?$/.test(location.pathname);
      const path = location.pathname.replace(/\/+$/, "");
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 8000);
      const res = await fetch(`${path}.json?raw_json=1&limit=200&depth=8${isComment ? "&context=3" : ""}`, { credentials: "include", signal: ctrl.signal });
      clearTimeout(timer);
      if (res.ok) redditJson = JSON.stringify(prune(await res.json())).replace(/</g, "\\u003c");
    } catch {
      redditJson = null;
    }
  }
  const root = document.implementation.createHTMLDocument("").importNode(document.documentElement, true);
  const drop = [
    'script:not([type="application/ld+json"])',
    "style",
    'link[rel~="stylesheet"]',
    'link[rel~="preload"]',
    'link[rel~="modulepreload"]',
    'link[rel~="prefetch"]',
    "template",
    "svg",
  ].join(",");
  for (const el of Array.from(root.querySelectorAll(drop))) el.remove();
  if (redditJson) {
    const s = root.ownerDocument.createElement("script");
    s.type = "application/json";
    s.id = "sroka-reddit-json";
    s.textContent = redditJson;
    (root.querySelector("body") ?? root).append(s);
  }
  return `<!doctype html>${root.outerHTML}`;
}

/** Capture rendered HTML of a tab; null on restricted pages or when too large. */
export async function captureHtml(tabId: number): Promise<string | null> {
  try {
    const [r] = await ext().scripting.executeScript({ target: { tabId }, func: pageHtmlForCapture });
    const html = r?.result as string | undefined;
    if (!html) return null;
    if (new TextEncoder().encode(html).length > MAX_CAPTURE_BYTES) return null;
    return html;
  } catch {
    return null;
  }
}

/** Save with queue fallback. Never throws. */
export async function saveWithFallback(body: SaveBody): Promise<SaveResult> {
  try {
    const r = await saveItem(body);
    await setCached(body.url, { saved: true, id: r.item.id });
    return { ok: true, item: r.item, created: r.created };
  } catch (e) {
    if (e instanceof ApiFailure) {
      if (e.status === 413 && body.html) return saveWithFallback({ ...body, html: undefined });
      if (e.status === 400 && e.code !== "invalid_url" && body.title) return saveWithFallback({ ...body, title: undefined });
      if (e.unauthorized || e.retryable) {
        try {
          await enqueue(body);
        } catch (qe) {
          return { ok: false, queued: false, reason: "error", message: `Could not queue save: ${qe instanceof Error ? qe.message : String(qe)}` };
        }
        return { ok: false, queued: true, reason: e.unauthorized ? "signed_out" : "offline", message: e.message };
      }
      return {
        ok: false,
        queued: false,
        reason: "error",
        message: e.code === "invalid_url" ? "This page can't be saved." : e.message,
      };
    }
    return { ok: false, queued: false, reason: "error", message: e instanceof Error ? e.message : String(e) };
  }
}

export async function saveTab(tab: { id?: number; url?: string; title?: string }): Promise<SaveResult> {
  if (!isSavableUrl(tab.url)) return { ok: false, queued: false, reason: "unsupported", message: "This page can't be saved." };
  const s = await getSettings();
  // Send the rendered page (default on): the tab has what the user's subscription unlocks and gets past bot walls
  // that block server fetches. Paywalled pages and Reddit are captured even when the user turned capture off.
  // The parser falls back to a server fetch when the capture yields little text (api.md §9).
  const page = tab.id != null ? await captureHtml(tab.id) : null;
  const html = page && (s.captureHtml || alwaysCapture(tab.url) || detectPaywall(page)) ? page : null;
  return saveWithFallback({ url: tab.url, title: tab.title?.trim().slice(0, LIMITS.maxTitleLength) || undefined, source: "extension", ...(html ? { html } : {}) });
}

export const saveLink = (url: string, title?: string): Promise<SaveResult> =>
  isSavableUrl(url)
    ? saveWithFallback({ url, title, source: "extension" })
    : Promise.resolve({ ok: false, queued: false, reason: "unsupported" });
