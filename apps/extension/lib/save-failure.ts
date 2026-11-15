/** Plain wording for the popup's "Couldn't save this page" body. The title already says it, so the body never repeats it. */

export const FAILED_TRY_AGAIN = "Try again, or reload the page and save it once it has loaded.";

// Messages that restate the title (or are an internal fallback), so they carry no extra information.
const GENERIC = /^(could not save this page|couldn[’']t save this page|this page can[’']t be saved)\.?$/i;

/** Body text for a failed save: a specific message when there is one, else the retry hint. */
export function failedBody(message?: string): string {
  const m = message?.trim();
  return m && !GENERIC.test(m) ? m : FAILED_TRY_AGAIN;
}
