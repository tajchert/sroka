import { ext } from "./chrome.ts";

/** D15: stored per browser in chrome.storage.local, not synced. */
export const CONSENT_KEY = "sroka.consent.v1";
export const CLIENT_ID_KEY = "sroka.ga.clientId";
export const SESSION_KEY = "sroka.ga.session";
/** Set (storage.local) after the first successful save from any path; the consent card waits for it. */
export const HAS_SAVED_KEY = "sroka.hasSaved.v1";
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

/** The card is possible only when a GA config was built in and the user has not decided yet (unanswered = off). */
export function shouldShowConsentPrompt(consent: Consent, config: AnalyticsConfig | null = analyticsConfig()): boolean {
  return config != null && consent.analytics === null;
}

export async function hasSavedOnce(): Promise<boolean> {
  const r = (await ext().storage.local.get(HAS_SAVED_KEY)) as Record<string, unknown>;
  return r[HAS_SAVED_KEY] === true;
}

export async function markSavedOnce(): Promise<void> {
  if (!(await hasSavedOnce())) await ext().storage.local.set({ [HAS_SAVED_KEY]: true });
}

/**
 * Should the saved popup show the consent card? Only after the user's first successful save (never at first run or
 * on the sign-in screen) and only while unanswered. The popup keeps its auto-close on hold while the card shows.
 */
export async function consentCardDue(config: AnalyticsConfig | null = analyticsConfig()): Promise<boolean> {
  if (!shouldShowConsentPrompt(await getConsent(), config)) return false;
  return hasSavedOnce();
}

/** The card renders only on the saved screen (never sign-in, saving, failed…), once `consentCardDue` said so. */
export function consentCardVisible(phase: string, due: boolean): boolean {
  return phase === "saved" && due;
}
