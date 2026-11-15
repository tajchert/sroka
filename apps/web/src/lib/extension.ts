/**
 * Talking to the Sroka extension installed in THIS browser (not the account-level `/v1/me` `clients.extension`).
 * Channel: the extension's manifest `externally_connectable` lists the Sroka web origins (https://sroka.app; localhost
 * in non-store builds), so Chrome exposes `chrome.runtime.sendMessage(extensionId, msg, cb)` to these pages only.
 * Contract (mirrors apps/extension/lib/resave.ts; documented in both CLAUDE.md files):
 *   { type: "sroka.ping" }                         → { ok: true, version }
 *   { type: "sroka.resave", itemId, url }          → { ok: true, opened: true, auto } | { ok: false, error }
 * `auto` = the extension saves the tab by itself once loaded (it already has host access to the site); otherwise the
 * opened tab's Sroka badge shows ↻ and the user's usual click on the Sroka button saves the full page.
 */

/**
 * Extension ids to try, in order: Chrome Web Store build first (most users), then the unpacked/dev build (manifest
 * `key`). The API's `EXT_ID` (comma-separated list) must contain the same ids.
 */
export const EXTENSION_IDS: readonly string[] = [
  "mgeodllnkiehnjbdogljfjgdbadjdblh", // Chrome Web Store
  "gmfnkkciofcaafddbcgphofiikmplema", // unpacked (manifest key)
];

const PING_TIMEOUT_MS = 1500;
const RESAVE_TIMEOUT_MS = 10_000;

export type ResaveError = "bad_origin" | "bad_request" | "not_in_library" | "signed_out" | "offline" | "error" | "no_extension";
export type ResaveReply = { ok: true; opened: true; auto: boolean } | { ok: false; error: ResaveError };

type Runtime = {
  sendMessage: (id: string, msg: unknown, cb: (reply: unknown) => void) => void;
  lastError?: { message?: string };
};

function runtime(): Runtime | null {
  const rt = (globalThis as { chrome?: { runtime?: Partial<Runtime> } }).chrome?.runtime;
  return rt && typeof rt.sendMessage === "function" ? (rt as Runtime) : null;
}

/** One message to one extension id; null when nothing answers (not installed, disabled, timeout, any error). */
function send(id: string, msg: unknown, timeoutMs: number): Promise<unknown> {
  const rt = runtime();
  if (!rt) return Promise.resolve(null);
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(null), timeoutMs);
    const done = (v: unknown) => {
      clearTimeout(timer);
      resolve(v);
    };
    try {
      rt.sendMessage(id, msg, (reply) => {
        // Reading lastError marks it handled (no "Unchecked runtime.lastError" console noise).
        done(rt.lastError ? null : (reply ?? null));
      });
    } catch {
      done(null);
    }
  });
}

let found: Promise<string | null> | null = null;

/** The id of the Sroka extension installed here, or null. Asked once per page load. */
export function findExtension(): Promise<string | null> {
  found ??= (async () => {
    if (!runtime()) return null;
    // Ping every id at once (worst case one timeout, not one per id); the first id in list order that answers wins.
    const replies = await Promise.all(
      EXTENSION_IDS.map((id) => send(id, { type: "sroka.ping" }, PING_TIMEOUT_MS) as Promise<{ ok?: unknown } | null>),
    );
    const i = replies.findIndex((r) => r?.ok === true);
    return i >= 0 ? EXTENSION_IDS[i]! : null;
  })();
  return found;
}

/** Test hook. */
export function resetExtensionDetection() {
  found = null;
}

/** Ask the extension to open the item's original and save that tab again once it has loaded. Call from a click. */
export async function resaveWithExtension(extensionId: string, item: { id: string; url: string }): Promise<ResaveReply> {
  const r = (await send(extensionId, { type: "sroka.resave", itemId: item.id, url: item.url }, RESAVE_TIMEOUT_MS)) as
    | { ok?: unknown; opened?: unknown; auto?: unknown; error?: unknown }
    | null;
  if (!r) return { ok: false, error: "no_extension" };
  if (r.ok === true && r.opened === true) return { ok: true, opened: true, auto: r.auto === true };
  return { ok: false, error: typeof r.error === "string" ? (r.error as ResaveError) : "error" };
}
