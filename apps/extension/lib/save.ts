import { LIMITS, type Item } from "@sroka/shared";
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

/** Capture rendered HTML of a tab; null on restricted pages or when too large. */
export async function captureHtml(tabId: number): Promise<string | null> {
  try {
    const [r] = await ext().scripting.executeScript({
      target: { tabId },
      func: () => document.documentElement.outerHTML,
    });
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
  const html = s.captureHtml && tab.id != null ? await captureHtml(tab.id) : null;
  return saveWithFallback({ url: tab.url, title: tab.title?.trim().slice(0, LIMITS.maxTitleLength) || undefined, source: "extension", ...(html ? { html } : {}) });
}

export const saveLink = (url: string, title?: string): Promise<SaveResult> =>
  isSavableUrl(url)
    ? saveWithFallback({ url, title, source: "extension" })
    : Promise.resolve({ ok: false, queued: false, reason: "unsupported" });
