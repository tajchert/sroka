import { beforeEach, describe, expect, it } from "vitest";
import { CONSENT_KEY, getConsent, resetConsentCache, setConsent } from "./consent.ts";

describe("consent store", () => {
  beforeEach(() => {
    localStorage.clear();
    resetConsentCache();
  });

  it("defaults to analytics unasked and crash reports on", () => {
    expect(getConsent()).toEqual({ analytics: null, errors: true });
  });

  it("persists changes and reloads them", () => {
    setConsent({ analytics: true });
    setConsent({ errors: false });
    expect(JSON.parse(localStorage.getItem(CONSENT_KEY)!)).toEqual({ analytics: true, errors: false });
    resetConsentCache();
    expect(getConsent()).toEqual({ analytics: true, errors: false });
  });

  it("falls back to defaults on corrupt storage", () => {
    localStorage.setItem(CONSENT_KEY, "{nope");
    expect(getConsent()).toEqual({ analytics: null, errors: true });
  });
});
