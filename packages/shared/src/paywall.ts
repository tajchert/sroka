/**
 * Paywall detection on a fetched/rendered page: a logged-out fetch of a paywalled article yields only the teaser,
 * which must be reported as `partial` / `paywalled` rather than `ok`. Never applied to captured HTML (the user's own
 * browser had access). Pure string heuristics; deliberately conservative.
 */

/** schema.org paywall markup (Google's required structured data for paywalled content), in JSON-LD. */
const LD_JSON = /<script[^>]+type=["']?application\/ld\+json["']?[^>]*>([\s\S]*?)<\/script>/gi;
const NOT_FREE = /"isAccessibleForFree"\s*:\s*(false|"false"|"False")/;

const MARKERS: readonly RegExp[] = [
  // <meta property="article:content_tier" content="locked"> (Substack, many news sites)
  /<meta[^>]+(?:property|name)=["']article:content_tier["'][^>]+content=["']locked["']/i,
  /<meta[^>]+content=["']locked["'][^>]+(?:property|name)=["']article:content_tier["']/i,
  // Medium member-only story banner
  />\s*Member-only story\s*</,
];

export function detectPaywall(html: string): boolean {
  for (const m of html.matchAll(LD_JSON)) if (NOT_FREE.test(m[1] ?? "")) return true;
  return MARKERS.some((re) => re.test(html));
}

/**
 * Sites that block server fetches outright (and serve challenges to headless browsers), so the extension always
 * sends the rendered page for them instead of only on paywalls. Matches the host and its subdomains.
 */
const ALWAYS_CAPTURE_HOSTS: readonly string[] = ["reddit.com"];

export function alwaysCapture(url: string): boolean {
  let host: string;
  try {
    host = new URL(url).hostname.toLowerCase();
  } catch {
    return false;
  }
  return ALWAYS_CAPTURE_HOSTS.some((h) => host === h || host.endsWith(`.${h}`));
}
