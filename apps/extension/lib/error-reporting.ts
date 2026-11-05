/** Extension error reporting → POST {server}/v1/client-errors (docs/api.md §12, D15). Best effort, never throws. */
import { ext } from "./chrome.ts";
import { getConsent } from "./consent.ts";
import { getSettings } from "./settings.ts";

export const MAX_PER_SESSION = 10;
const seen = new Set<string>();
let sent = 0;

export function resetErrorReporting(): void {
  seen.clear();
  sent = 0;
}

function release(): string {
  try {
    return `ext-${ext().runtime.getManifest().version}`;
  } catch {
    return "ext-unknown";
  }
}

function safeString(v: unknown): string {
  try {
    return typeof v === "object" ? JSON.stringify(v) : String(v);
  } catch {
    return "unserializable error";
  }
}

/** Reports once per distinct message+stack-head, at most MAX_PER_SESSION per context lifetime. Returns whether sent. */
export async function reportClientError(err: unknown, extra?: string): Promise<boolean> {
  try {
    if (!(await getConsent()).errors) return false;
    const e = err instanceof Error ? err : new Error(typeof err === "string" ? err : safeString(err));
    const message = (extra ? `${extra}: ` : "") + e.message;
    const stack = e.stack ?? "";
    const key = `${message}|${stack.split("\n").slice(0, 3).join("|")}`;
    if (seen.has(key) || sent >= MAX_PER_SESSION) return false;
    seen.add(key);
    sent++;
    const { serverUrl } = await getSettings();
    // Only the extension page path (e.g. /popup.html), never a tab URL or item data.
    const body = JSON.stringify({
      message: message.slice(0, 1000) || "unknown error",
      stack: stack.slice(0, 4096),
      url: globalThis.location?.pathname ?? "/background",
      userAgent: globalThis.navigator?.userAgent,
      release: release(),
    });
    await fetch(`${serverUrl}/v1/client-errors`, { method: "POST", headers: { "Content-Type": "application/json" }, body }).catch(() => undefined);
    return true;
  } catch {
    return false;
  }
}

let installed = false;
/** error + unhandledrejection in a window or the service worker. Idempotent. */
export function installGlobalErrorHandlers(): void {
  if (installed) return;
  installed = true;
  globalThis.addEventListener("error", (ev) => void reportClientError(ev.error ?? ev.message, "uncaught"));
  globalThis.addEventListener("unhandledrejection", (ev) => void reportClientError(ev.reason, "unhandledrejection"));
}
