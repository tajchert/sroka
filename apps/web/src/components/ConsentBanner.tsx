import { setConsent, useConsent } from "../lib/consent.ts";
import { hasAnalyticsConfig } from "../lib/firebase-config.ts";

/** First-run analytics prompt (D15). Non-blocking; either button records the decision. Render only when signed in. */
export function ConsentBanner() {
  const consent = useConsent();
  if (!hasAnalyticsConfig() || consent.analytics !== null) return null;
  return (
    <section
      aria-labelledby="consent-title"
      className="fixed inset-x-3 bottom-3 z-30 rounded-2xl border border-rule bg-paper2 p-4 shadow-[0_18px_50px_rgb(0_0_0/.25)] sm:right-auto sm:left-4 sm:w-[380px] md:left-[248px]"
    >
      <h2 id="consent-title" className="text-[15px] font-semibold">Help improve Sroka?</h2>
      <p className="mt-1 text-sm text-ink2">
        Share anonymous usage statistics (which features are used, never what you read) via Google Analytics. You can change this anytime in Settings.
      </p>
      <div className="mt-3 flex flex-wrap items-center gap-2">
        <button type="button" className="btn btn-primary" onClick={() => setConsent({ analytics: true })}>Allow</button>
        <button type="button" className="btn" onClick={() => setConsent({ analytics: false })}>No thanks</button>
        <a className="ml-auto text-xs text-link hover:underline" href="/privacy" target="_blank" rel="noopener noreferrer">Privacy policy</a>
      </div>
    </section>
  );
}
