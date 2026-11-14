/** Client error reporting → POST /v1/client-errors (docs/api.md §12, docs/observability.md). Best effort, never throws. */

import { screenForPath } from "./analytics.ts";
import { getConsent } from "./consent.ts";

const MAX_PER_SESSION = 10;
const seen = new Set<string>();
let sent = 0;

export function resetErrorReporting(): void {
  seen.clear();
  sent = 0;
}

function release(): string {
  try {
    return (import.meta.env.VITE_RELEASE as string | undefined) ?? "dev";
  } catch {
    return "dev";
  }
}

/** The screen name only: the raw path carries tag names and item ids. */
function screenName(): string {
  const path = location.pathname.replace(/^\/app(?=\/|$)/, "") || "/";
  return screenForPath(path)?.screen_name ?? "other";
}

/** Reports once per distinct message+stack-head, at most MAX_PER_SESSION per page session. Returns whether sent. */
export function reportClientError(err: unknown, extra?: string): boolean {
  try {
    if (!getConsent().errors) return false; // D15: user opted out of crash reports
    const e = err instanceof Error ? err : new Error(typeof err === "string" ? err : safeString(err));
    const message = (extra ? `${extra}: ` : "") + e.message;
    const stack = e.stack ?? "";
    const key = `${message}|${stack.split("\n").slice(0, 3).join("|")}`;
    if (seen.has(key) || sent >= MAX_PER_SESSION) return false;
    seen.add(key);
    sent++;
    const body = JSON.stringify({
      message: message.slice(0, 1000) || "unknown error",
      stack: stack.slice(0, 4096),
      url: screenName(),
      userAgent: navigator.userAgent,
      release: release(),
    });
    void fetch("/v1/client-errors", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
      keepalive: true,
    }).catch(() => undefined);
    return true;
  } catch {
    return false;
  }
}

function safeString(v: unknown): string {
  try {
    return typeof v === "object" ? JSON.stringify(v) : String(v);
  } catch {
    return "unserializable error";
  }
}

let installed = false;
/** window.onerror + unhandledrejection. Idempotent. */
export function installGlobalErrorHandlers(): void {
  if (installed || typeof window === "undefined") return;
  installed = true;
  window.addEventListener("error", (ev) => {
    reportClientError(ev.error ?? ev.message, "window.onerror");
  });
  window.addEventListener("unhandledrejection", (ev) => {
    reportClientError(ev.reason, "unhandledrejection");
  });
}
