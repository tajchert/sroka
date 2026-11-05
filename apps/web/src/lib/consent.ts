/** Per-browser consent (D15): localStorage `sroka.consent.v1`. Analytics is opt-in (null = not asked), crash reports opt-out. */
import { useSyncExternalStore } from "react";

export interface Consent {
  analytics: boolean | null;
  errors: boolean;
}

export const CONSENT_KEY = "sroka.consent.v1";

let cache: Consent | null = null;
const listeners = new Set<() => void>();

function read(): Consent {
  try {
    const raw = localStorage.getItem(CONSENT_KEY);
    if (raw) {
      const v = JSON.parse(raw) as Partial<Consent>;
      return {
        analytics: typeof v.analytics === "boolean" ? v.analytics : null,
        errors: typeof v.errors === "boolean" ? v.errors : true,
      };
    }
  } catch {
    /* storage unavailable or corrupt: defaults */
  }
  return { analytics: null, errors: true };
}

export function getConsent(): Consent {
  return (cache ??= read());
}

export function setConsent(patch: Partial<Consent>): void {
  cache = { ...getConsent(), ...patch };
  try {
    localStorage.setItem(CONSENT_KEY, JSON.stringify(cache));
  } catch {
    /* in-memory only */
  }
  for (const l of listeners) l();
}

export function subscribeConsent(l: () => void): () => void {
  listeners.add(l);
  return () => listeners.delete(l);
}

/** Test helper: forget the in-memory copy so the next read hits localStorage again. */
export function resetConsentCache(): void {
  cache = null;
}

export function useConsent(): Consent {
  return useSyncExternalStore(subscribeConsent, getConsent, getConsent);
}
