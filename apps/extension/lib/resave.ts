import { isUuid, log, tryNormalizeUrl, type Item } from "@sroka/shared";
import { ApiFailure, getItem } from "./api.ts";
import { ext } from "./chrome.ts";
import type { SaveResult } from "./save.ts";

/**
 * "Re-save with extension" (web reader, paywalled "Preview only" items). Channel: manifest `externally_connectable`
 * (no permission warning, no host permission): the Sroka web app calls `chrome.runtime.sendMessage(EXT_ID, msg)`.
 * Contract (mirrored in apps/web/src/lib/extension.ts, documented in both CLAUDE.md files):
 *   { type: "sroka.ping" }                              → { ok: true, version }
 *   { type: "sroka.resave", itemId: uuid, url: http(s) } → { ok: true, opened: true } | { ok: false, error }
 * The extension checks the sender origin against its own `externally_connectable.matches`, fetches the item with its
 * own token (so it must be in the extension's signed-in library and its URL must match) and opens the item's URL in a
 * new tab. Only that tab is ever re-saved, with its rendered HTML (forced capture), once it shows the same page:
 * - automatically, when the extension already has host access to the site (rare: `optional_host_permissions`);
 * - otherwise on the user's next click on the toolbar button / shortcut / "Save page" menu in that tab. Capturing a page
 *   needs `activeTab` (granted only by such a gesture) or a host permission; a web-page message grants neither, and we
 *   add no permission for this. Until then the tab's badge shows a hint (RESAVE_BADGE) instead of the saved tick.
 */
export const RESAVE_KEY = "sroka.resave.v1"; // storage.session: { [tabId]: Pending }
export const RESAVE_TTL_MS = 10 * 60_000;
export const SETTLE_MS = 1500;
export const RESAVE_BADGE = "↻";
export const RESAVE_TITLE = "Click to save the full page to Sroka";

export type ExternalMsg = { type: "sroka.ping" } | { type: "sroka.resave"; itemId: string; url: string };
export type ResaveError = "bad_origin" | "bad_request" | "not_in_library" | "signed_out" | "offline" | "error";
/** `auto`: the extension can capture the tab itself; false = the user clicks the toolbar button in that tab. */
export type ExternalReply =
  | { ok: true; version: string }
  | { ok: true; opened: true; auto: boolean }
  | { ok: false; error: ResaveError };

interface Pending {
  itemId: string;
  url: string;
  /** Normalized page keys (item url + canonical url) the tab must show before it is saved. */
  targets: string[];
  expires: number;
}
type PendingMap = Record<string, Pending>;

export type Sender = { origin?: string; url?: string; tab?: { id?: number; index?: number; windowId?: number } };

/** Does `origin` match one of the manifest's externally_connectable patterns (`scheme://host/*`, no port = any port)? */
export function allowedOrigin(origin: string | undefined, matches: readonly string[]): boolean {
  if (!origin) return false;
  let o: URL;
  try {
    o = new URL(origin);
  } catch {
    return false;
  }
  return matches.some((p) => {
    const m = /^(https?):\/\/([^/]+)\/\*$/.exec(p);
    if (!m) return false;
    const [host, port] = m[2]!.split(":");
    return o.protocol === `${m[1]}:` && o.hostname === host && (port == null || port === "*" || o.port === port);
  });
}

const isHttp = (s: string) => {
  try {
    const u = new URL(s);
    return u.protocol === "https:" || u.protocol === "http:";
  } catch {
    return false;
  }
};

export function parseExternal(msg: unknown): ExternalMsg | null {
  if (!msg || typeof msg !== "object") return null;
  const m = msg as Record<string, unknown>;
  if (m.type === "sroka.ping") return { type: "sroka.ping" };
  if (m.type === "sroka.resave" && isUuid(m.itemId) && typeof m.url === "string" && m.url.length <= 8192 && isHttp(m.url)) {
    return { type: "sroka.resave", itemId: m.itemId, url: m.url };
  }
  return null;
}

/** Same page, tolerant of redirects that only change scheme, `www.`, tracking params or a trailing slash. */
export function pageKey(url: string | undefined): string | null {
  if (!url || !isHttp(url)) return null;
  const n = tryNormalizeUrl(url);
  if (!n) return null;
  const u = new URL(n);
  return `${u.hostname.replace(/^www\./, "")}${u.pathname.replace(/\/+$/, "")}${u.search}`;
}

function senderOrigin(s: Sender): string | undefined {
  if (s.origin) return s.origin;
  try {
    return s.url ? new URL(s.url).origin : undefined;
  } catch {
    return undefined;
  }
}

const manifestMatches = (): string[] =>
  (ext().runtime.getManifest() as { externally_connectable?: { matches?: string[] } }).externally_connectable?.matches ?? [];

async function readPending(now: number): Promise<PendingMap> {
  const r = (await ext().storage.session.get(RESAVE_KEY)) as Record<string, PendingMap | undefined>;
  const all = r[RESAVE_KEY] ?? {};
  return Object.fromEntries(Object.entries(all).filter(([, p]) => p.expires > now));
}
const writePending = (m: PendingMap) => ext().storage.session.set({ [RESAVE_KEY]: m });

/** Host access to the page's origin (no prompt; just asks whether it is already granted). */
export async function hasHostAccess(url: string | undefined): Promise<boolean> {
  try {
    if (!url || !isHttp(url)) return false;
    return await ext().permissions.contains({ origins: [`${new URL(url).origin}/*`] });
  } catch {
    return false;
  }
}

async function paintHint(tabId: number) {
  const a = ext().action;
  await a.setBadgeText({ tabId, text: RESAVE_BADGE });
  await a.setBadgeBackgroundColor({ tabId, color: "#b45309" });
  await a.setBadgeTextColor?.({ tabId, color: "#ffffff" });
  await a.setTitle({ tabId, title: RESAVE_TITLE });
}

function errorOf(e: unknown): ResaveError {
  if (e instanceof ApiFailure) {
    if (e.unauthorized) return "signed_out";
    if (e.status === 404) return "not_in_library";
    if (e.retryable) return "offline";
  }
  return "error";
}

/** chrome.runtime.onMessageExternal handler. Never throws. */
export async function handleExternal(msg: unknown, sender: Sender, now = Date.now()): Promise<ExternalReply> {
  if (!allowedOrigin(senderOrigin(sender), manifestMatches())) return { ok: false, error: "bad_origin" };
  const m = parseExternal(msg);
  if (!m) return { ok: false, error: "bad_request" };
  if (m.type === "sroka.ping") return { ok: true, version: ext().runtime.getManifest().version };
  // Only a page in a tab (not a worker or a background frame) may ask to open one.
  if (sender.tab?.id == null) return { ok: false, error: "bad_request" };
  let item: Item;
  try {
    item = await getItem(m.itemId);
  } catch (e) {
    const error = errorOf(e);
    log.info("resave refused", { event: "ext_resave_refused", reason: error });
    return { ok: false, error };
  }
  const targets = [pageKey(item.url), pageKey(item.canonicalUrl ?? undefined)].filter((k): k is string => !!k);
  const asked = pageKey(m.url);
  if (!asked || !targets.includes(asked) || !isHttp(item.url)) {
    log.info("resave refused", { event: "ext_resave_refused", reason: "url_mismatch" });
    return { ok: false, error: "not_in_library" };
  }
  try {
    const tab = await ext().tabs.create({
      url: item.url,
      active: true,
      openerTabId: sender.tab.id,
      ...(sender.tab.index != null ? { index: sender.tab.index + 1 } : {}),
      ...(sender.tab.windowId != null ? { windowId: sender.tab.windowId } : {}),
    });
    if (tab.id == null) return { ok: false, error: "error" };
    const pending = await readPending(now);
    pending[String(tab.id)] = { itemId: item.id, url: item.url, targets, expires: now + RESAVE_TTL_MS };
    await writePending(pending);
    const auto = await hasHostAccess(item.url);
    log.info("resave tab opened", { event: "ext_resave_opened", auto });
    return { ok: true, opened: true, auto };
  } catch (e) {
    log.warnException("resave open failed", e, { event: "ext_resave_open_failed" });
    return { ok: false, error: "error" };
  }
}

export interface ResaveDeps {
  save: (tab: { id: number; url: string; title?: string }) => Promise<SaveResult>;
  delay?: (ms: number) => Promise<void>;
  now?: () => number;
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/**
 * chrome.tabs.onUpdated hook: when a tab this module opened finishes loading the requested page, save it once if the
 * extension can capture it, else show the badge hint and wait for the user's click (`takeResave`).
 * A tab on another page (login redirect) stays pending until it comes back or the request expires (10 min).
 * Returns the save result, or null when nothing was saved.
 */
export async function onResaveTabUpdated(
  tabId: number,
  change: { status?: string },
  tab: { url?: string; title?: string },
  deps: ResaveDeps,
): Promise<SaveResult | null> {
  if (change.status !== "complete") return null;
  const now = deps.now?.() ?? Date.now();
  const pending = await readPending(now);
  const p = pending[String(tabId)];
  if (!p) return null;
  const key = pageKey(tab.url);
  if (!key || !p.targets.includes(key)) return null;
  if (!(await hasHostAccess(tab.url))) {
    await paintHint(tabId).catch(() => undefined);
    return null;
  }
  // Claim it before the settle delay, so a second "complete" (SPA, reload) cannot save twice.
  delete pending[String(tabId)];
  await writePending(pending);
  await (deps.delay ?? sleep)(SETTLE_MS);
  let current: { url?: string; title?: string };
  try {
    current = await ext().tabs.get(tabId);
  } catch {
    return null; // closed meanwhile
  }
  if (pageKey(current.url) !== key) return null;
  return deps.save({ id: tabId, url: p.url, title: current.title });
}

/**
 * A user save in `tabId` (popup, shortcut, "Save page" menu): if this tab was opened for a re-save and shows that page,
 * claim it and return the item's URL, so the caller saves with forced capture under the library item's URL.
 */
export async function takeResave(tabId: number | undefined, url: string | undefined, now = Date.now()): Promise<{ url: string } | null> {
  if (tabId == null) return null;
  const pending = await readPending(now);
  const p = pending[String(tabId)];
  const key = pageKey(url);
  if (!p || !key || !p.targets.includes(key)) return null;
  delete pending[String(tabId)];
  await writePending(pending);
  await ext().action.setTitle({ tabId, title: "" }).catch(() => undefined); // back to the default title
  return { url: p.url };
}

/** Badge hint wanted for this tab (refreshBadge paints it instead of the saved tick)? */
export async function resaveHintFor(tabId: number, url: string | undefined, now = Date.now()): Promise<boolean> {
  const p = (await readPending(now))[String(tabId)];
  const key = pageKey(url);
  return !!p && !!key && p.targets.includes(key);
}

export { paintHint as paintResaveHint };

/** chrome.tabs.onRemoved hook. */
export async function forgetResaveTab(tabId: number): Promise<void> {
  const pending = await readPending(Date.now());
  if (!(String(tabId) in pending)) return;
  delete pending[String(tabId)];
  await writePending(pending);
}
