import { ext } from "./chrome.ts";

/** D15: stored per browser in chrome.storage.local, not synced. */
export const CONSENT_KEY = "sroka.consent.v1";
export const CLIENT_ID_KEY = "sroka.ga.clientId";
export const SESSION_KEY = "sroka.ga.session";
export const PRIVACY_URL = "https://sroka.app/privacy";
export const TERMS_URL = "https://sroka.app/terms";

export interface Consent {
  /** null = not asked yet. Opt-in: nothing is sent unless true. */
  analytics: boolean | null;
  /** Error reports: on by default, opt-out. */
  errors: boolean;
}

export interface AnalyticsConfig {
  measurementId: string;
  apiSecret: string;
}

/** Build-time config from analytics.config.json; null (no telemetry UI, nothing sent) when the build had none. */
export function analyticsConfig(): AnalyticsConfig | null {
  try {
    return typeof __SROKA_GA__ !== "undefined" && __SROKA_GA__ ? __SROKA_GA__ : null;
  } catch {
    return null;
  }
}

export async function getConsent(): Promise<Consent> {
  const r = (await ext().storage.local.get(CONSENT_KEY)) as Record<string, Partial<Consent> | undefined>;
  const c = r[CONSENT_KEY];
  return { analytics: typeof c?.analytics === "boolean" ? c.analytics : null, errors: c?.errors !== false };
}

/** Revoking analytics deletes the client id and session, so a later opt-in starts from a fresh anonymous id. */
export async function setConsent(patch: Partial<Consent>): Promise<Consent> {
  const next = { ...(await getConsent()), ...patch };
  await ext().storage.local.set({ [CONSENT_KEY]: next });
  if (next.analytics !== true) {
    await ext().storage.local.remove(CLIENT_ID_KEY);
    await ext().storage.session.remove(SESSION_KEY);
  }
  return next;
}

/** The first-run card is shown only when a GA config was built in and the user has not decided yet. */
export function shouldShowConsentPrompt(consent: Consent, config: AnalyticsConfig | null = analyticsConfig()): boolean {
  return config != null && consent.analytics === null;
}
