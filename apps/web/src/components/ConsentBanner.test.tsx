import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const cfg = vi.hoisted(() => ({ on: true }));
vi.mock("../lib/firebase-config.ts", () => ({ hasAnalyticsConfig: () => cfg.on, firebaseConfig: null }));

import { getConsent, resetConsentCache } from "../lib/consent.ts";
import { PrivacySection } from "../routes/Settings.tsx";
import { ConsentBanner } from "./ConsentBanner.tsx";

beforeEach(() => {
  localStorage.clear();
  resetConsentCache();
  cfg.on = true;
});
afterEach(cleanup);

describe("ConsentBanner", () => {
  it("shows the prompt with the policy link when unasked", () => {
    render(<ConsentBanner />);
    expect(screen.getByText("Help improve Sroka?")).toBeTruthy();
    const link = screen.getByRole("link", { name: "Privacy policy" });
    expect(link.getAttribute("href")).toBe("/privacy");
    expect(link.getAttribute("target")).toBe("_blank");
  });

  it("Allow records consent and hides", () => {
    render(<ConsentBanner />);
    fireEvent.click(screen.getByRole("button", { name: "Allow" }));
    expect(getConsent().analytics).toBe(true);
    expect(screen.queryByText("Help improve Sroka?")).toBeNull();
  });

  it("No thanks records refusal and hides", () => {
    render(<ConsentBanner />);
    fireEvent.click(screen.getByRole("button", { name: "No thanks" }));
    expect(getConsent().analytics).toBe(false);
    expect(screen.queryByText("Help improve Sroka?")).toBeNull();
  });

  it("stays hidden without config or after a decision", () => {
    cfg.on = false;
    const { container } = render(<ConsentBanner />);
    expect(container.innerHTML).toBe("");
  });
});

describe("Settings privacy section", () => {
  it("toggles analytics and crash reports", () => {
    render(<PrivacySection />);
    const analytics = screen.getByLabelText(/Share usage analytics/) as HTMLInputElement;
    const errors = screen.getByLabelText(/Send crash reports/) as HTMLInputElement;
    expect(analytics.checked).toBe(false);
    expect(errors.checked).toBe(true);
    fireEvent.click(analytics);
    fireEvent.click(errors);
    expect(getConsent()).toEqual({ analytics: true, errors: false });
    expect(screen.getByRole("link", { name: "Terms of service" }).getAttribute("href")).toBe("/terms");
  });

  it("hides the analytics toggle without config", () => {
    cfg.on = false;
    render(<PrivacySection />);
    expect(screen.queryByLabelText(/Share usage analytics/)).toBeNull();
    expect(screen.getByLabelText(/Send crash reports/)).toBeTruthy();
  });
});
