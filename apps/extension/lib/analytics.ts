import { ext } from "./chrome.ts";
import { analyticsConfig, CLIENT_ID_KEY, getConsent, SESSION_KEY } from "./consent.ts";
import type { Msg } from "./messages.ts";

/** D15 event catalogue (extension subset). Params are limited to these enums; anything else is dropped. */
export type AnalyticsEvent =
  | { name: "popup_open" }
  | { name: "open_library" }
  | { name: "login"; params: { method: "email_otp" } }
  | { name: "save_item"; params: { source: "extension" | "context_menu"; kind: "article" | "pdf" } };

const ENUMS: Record<string, Record<string, readonly string[]>> = {
  login: { method: ["email_otp"] },
  save_item: { source: ["extension", "context_menu"], kind: ["article", "pdf"] },
};

export const SESSION_MS = 30 * 60 * 1000;
const ENDPOINT = "https://www.google-analytics.com/mp/collect";

let clientIdPending: Promise<string> | null = null;
async function clientId(): Promise<string> {
  const r = await ext().storage.local.get(CLIENT_ID_KEY);
  const existing = r[CLIENT_ID_KEY];
  if (typeof existing === "string") return existing;
  clientIdPending ??= (async () => {
    const id = crypto.randomUUID();
    await ext().storage.local.set({ [CLIENT_ID_KEY]: id });
    return id;
  })().finally(() => (clientIdPending = null));
  return clientIdPending;
}

/** 30-minute inactivity sessions; the id is the session start in unix seconds (GA convention). */
async function sessionId(now: number): Promise<number> {
  const r = (await ext().storage.session.get(SESSION_KEY)) as Record<string, { id: number; last: number } | undefined>;
  const cur = r[SESSION_KEY];
  const id = cur && now - cur.last < SESSION_MS ? cur.id : Math.floor(now / 1000);
  await ext().storage.session.set({ [SESSION_KEY]: { id, last: now } });
  return id;
}

function cleanParams(name: string, params: Record<string, unknown> | undefined): Record<string, string> {
  const allowed = ENUMS[name] ?? {};
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(params ?? {})) {
    if (typeof v === "string" && allowed[k]?.includes(v)) out[k] = v;
  }
  return out;
}

/**
 * Background-only: sends one GA4 Measurement Protocol hit. No-op without a build-time config or without
 * analytics consent (no client id exists before consent). Never throws.
 */
export async function trackEvent(ev: AnalyticsEvent, now = Date.now()): Promise<boolean> {
  try {
    const cfg = analyticsConfig();
    if (!cfg) return false;
    if ((await getConsent()).analytics !== true) return false;
    const params = {
      ...cleanParams(ev.name, "params" in ev ? ev.params : undefined),
      session_id: await sessionId(now),
      engagement_time_msec: 100,
    };
    const payload = {
      client_id: await clientId(),
      // Ad signals are always denied (D15).
      consent: { ad_user_data: "DENIED", ad_personalization: "DENIED" },
      non_personalized_ads: true,
      events: [{ name: ev.name, params }],
    };
    // A string body with no-cors is a simple request, so no host permission or CORS preflight is needed.
    const url = `${ENDPOINT}?measurement_id=${encodeURIComponent(cfg.measurementId)}&api_secret=${encodeURIComponent(cfg.apiSecret)}`;
    await fetch(url, { method: "POST", mode: "no-cors", body: JSON.stringify(payload) });
    return true;
  } catch {
    return false;
  }
}

type Sink = (ev: AnalyticsEvent) => Promise<unknown>;
const viaMessage: Sink = (ev) => ext().runtime.sendMessage({ type: "track", event: ev } satisfies Msg);
let sink: Sink = viaMessage;

/** The background installs `trackEvent` as the sink; popup/options pages default to a runtime message. */
export function setTrackSink(s: Sink | null): void {
  sink = s ?? viaMessage;
}

/** Fire-and-forget from any extension context. */
export function track(ev: AnalyticsEvent): void {
  try {
    void Promise.resolve(sink(ev)).catch(() => undefined);
  } catch {
    /* telemetry never breaks the app */
  }
}
