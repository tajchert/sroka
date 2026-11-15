/**
 * One set of user-facing words for web and extension (Android mirrors them in strings.xml).
 * Short labels go in tooltips / aria-labels / chips; `*Title` strings are the reader's full-page titles.
 */
export const VOCAB = {
  pending: "Preparing…",
  pendingTitle: "Preparing article",
  failed: "Couldn't save the text",
  failedTitle: "Couldn't save the text",
  partial: "Partial copy",
  partialTitle: "Partial copy",
  paywalled: "Preview only",
  paywalledTitle: "Preview only",
  downloading: "Downloading",
  notDownloaded: "Not on this device",
  unsynced: "Waiting to sync",
  read: "Read",
  save: "Save",
  saved: "Saved",
  favorites: "Favorites",
  favorite: "Favorite",
  sendCode: "Send code",
} as const;

export type VocabKey = keyof typeof VOCAB;

const REASONS = {
  blocked: "The site blocks Sroka.",
  paywalled: "It's for subscribers only.",
  gone: "The page is gone.",
  noResponse: "The site didn't respond.",
  tooLarge: "The page is too large.",
  notArticle: "It isn't an article.",
} as const;

const EXACT: Record<string, string> = {
  bot_wall: REASONS.blocked,
  render_bot_wall: REASONS.blocked,
  paywalled: REASONS.paywalled,
  http_404: REASONS.gone,
  http_410: REASONS.gone,
  timeout: REASONS.noResponse,
  network: REASONS.noResponse,
  too_many_redirects: REASONS.noResponse,
  bad_redirect: REASONS.noResponse,
  too_large: REASONS.tooLarge,
  render_too_large: REASONS.tooLarge,
  pdf_too_large: REASONS.tooLarge,
  not_html: REASONS.notArticle,
};

/**
 * Plain-language reason for an item's `parseError` code (never show the raw code). `null` when there is
 * no code or no sentence for it; callers then show only the title.
 */
export function failureReason(parseError: string | null | undefined): string | null {
  if (!parseError) return null;
  if (Object.hasOwn(EXACT, parseError)) return EXACT[parseError]!;
  if (parseError.startsWith("http_")) return REASONS.noResponse;
  return null;
}
