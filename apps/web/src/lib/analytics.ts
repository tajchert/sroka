/**
 * Firebase Analytics (D15). Opt-in and lazy: `firebase/*` is only dynamically imported once a config is baked into
 * the build AND the user allowed analytics. Never send URLs, titles, search text, tag names, ids or emails; no user id.
 */
import { log } from "@sroka/shared";
import { getConsent, subscribeConsent } from "./consent.ts";
import { firebaseConfig } from "./firebase-config.ts";

export type ScreenName = "sign_in" | "library" | "reader" | "search" | "tags" | "settings" | "import" | "export" | "share";
export type ItemKind = "article" | "pdf";
export type AnalyticsEvent =
  | { name: "login"; params: { method: "email_otp" } }
  | { name: "save_item"; params: { source: "web_add" | "pdf" | "drag" | "share" | "import"; kind: ItemKind } }
  | { name: "open_item"; params: { kind: ItemKind } }
  | { name: "archive_item" | "unarchive_item" | "delete_item" | "add_tag" | "search_used"; params?: undefined }
  | { name: "favorite_item"; params: { on: boolean } }
  | { name: "import_start"; params: { source: "pocket_csv" | "pocket_html" | "instapaper_csv" | "netscape_html" } }
  | { name: "export"; params: { format: "csv" | "json" } };

export interface Screen {
  screen_name: ScreenName;
  /** Route pattern under /app, never the real path. */
  page_path: string;
}

/** Router pathname (basename already stripped) -> D15 screen + route pattern. Null for unreported routes (admin). */
export function screenForPath(pathname: string): Screen | null {
  const p = pathname.replace(/\/+$/, "") || "/";
  const lib = (route: string): Screen => ({ screen_name: "library", page_path: route === "/" ? "/app" : `/app${route}` });
  if (p === "/" || p === "/archive" || p === "/favorites" || p === "/all") return lib(p);
  if (p.startsWith("/tag/")) return lib("/tag/:name");
  if (p === "/search") return { screen_name: "search", page_path: "/app/search" };
  if (p === "/tags") return { screen_name: "tags", page_path: "/app/tags" };
  if (p.startsWith("/item/")) return { screen_name: "reader", page_path: "/app/item/:id" };
  if (p === "/settings") return { screen_name: "settings", page_path: "/app/settings" };
  if (p === "/share") return { screen_name: "share", page_path: "/app/share" };
  if (p === "/admin") return null;
  return lib("/"); // unknown paths render the library
}

export const SIGN_IN_SCREEN: Screen = { screen_name: "sign_in", page_path: "/app" };

type AnalyticsMod = typeof import("firebase/analytics");
interface Live {
  mod: AnalyticsMod;
  instance: ReturnType<AnalyticsMod["initializeAnalytics"]>;
}

let live: Live | null = null;
let loading = false;
let screen: Screen | null = null;
let started = false;

const GRANTED = { analytics_storage: "granted", ad_storage: "denied", ad_user_data: "denied", ad_personalization: "denied" } as const;
const DENIED = { analytics_storage: "denied", ad_storage: "denied", ad_user_data: "denied", ad_personalization: "denied" } as const;

/** The SDK's typed overloads reject custom names; our names/params are constrained by AnalyticsEvent instead. */
function rawLog(l: Live, name: string, params?: object): void {
  (l.mod.logEvent as (i: Live["instance"], n: string, p?: object) => void)(l.instance, name, params);
}

function pageParams(s: Screen): { page_location: string; page_path: string } {
  return { page_location: location.origin + s.page_path, page_path: s.page_path };
}

function sendScreenView(): void {
  if (!live || !screen || getConsent().analytics !== true) return;
  live.mod.setDefaultEventParameters(pageParams(screen)); // every later event carries the sanitized location
  rawLog(live, "screen_view", { screen_name: screen.screen_name, ...pageParams(screen) });
}

/** Delete Google Analytics cookies (`_ga`, `_ga_<id>`) on this host and its parent domains. */
export function deleteGaCookies(): void {
  try {
    const names = document.cookie.split(";").map((c) => c.split("=")[0]!.trim()).filter((n) => n.startsWith("_ga"));
    const parts = location.hostname.split(".");
    const domains = ["", ...parts.slice(0, -1).map((_, i) => "." + parts.slice(i).join("."))];
    for (const n of names) {
      for (const d of domains) document.cookie = `${n}=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/${d ? `; domain=${d}` : ""}`;
    }
  } catch {
    /* ignore */
  }
}

async function load(): Promise<void> {
  if (!firebaseConfig) return;
  const [{ initializeApp }, mod] = await Promise.all([import("firebase/app"), import("firebase/analytics")]);
  if (getConsent().analytics !== true) return; // revoked while loading
  mod.setConsent(GRANTED);
  const app = initializeApp(firebaseConfig);
  const instance = mod.initializeAnalytics(app, {
    config: { send_page_view: false, allow_google_signals: false, allow_ad_personalization_signals: false },
  });
  live = { mod, instance };
  sendScreenView();
}

function apply(): void {
  const on = firebaseConfig !== null && getConsent().analytics === true;
  if (on) {
    if (live) {
      live.mod.setConsent(GRANTED);
      live.mod.setAnalyticsCollectionEnabled(live.instance, true);
      sendScreenView();
    } else if (!loading) {
      loading = true;
      load()
        .catch((e: unknown) => log.warn("analytics_load_failed", { event: "analytics_load_failed", error: e instanceof Error ? e.message : "unknown" }))
        .finally(() => {
          loading = false;
          // consent flipped on again while a revoked load was in flight
          if (!live && firebaseConfig && getConsent().analytics === true) apply();
        });
    }
  } else if (live) {
    live.mod.setAnalyticsCollectionEnabled(live.instance, false);
    live.mod.setConsent(DENIED);
    deleteGaCookies();
  }
}

/** Apply the stored consent now and on every change. Idempotent. */
export function startAnalytics(): void {
  if (started) return;
  started = true;
  subscribeConsent(apply);
  apply();
}

/** Called on route change and sign-in/out. `null` = nothing to report. */
export function setScreen(next: Screen | null): void {
  screen = next;
  sendScreenView();
}

/** Fire-and-forget event; no-op unless analytics is loaded and consented. */
export function track(e: AnalyticsEvent): void {
  if (!live || getConsent().analytics !== true) return;
  try {
    rawLog(live, e.name, e.params);
  } catch {
    /* never break the app for telemetry */
  }
}

/** Test helper. */
export function resetAnalytics(): void {
  live = null;
  loading = false;
  screen = null;
  started = false;
}
