/**
 * Bot-wall / JS-wall detection on a fetched 2xx HTML page (decisions D10: such pages trigger the Browser Run
 * fallback). Pure string heuristics over the first 64 KB; deliberately conservative.
 */
export type BotWall = "challenge" | "js_required";

/** HTTP statuses that typically mean "blocked by a bot wall" rather than "page doesn't exist". */
export const BOT_WALL_STATUSES: readonly number[] = [403, 429, 503];

const CHALLENGE_MARKERS: readonly RegExp[] = [
  // Cloudflare managed challenge / JS challenge / block page
  /<title>\s*Just a moment\.\.\.\s*<\/title>/i,
  /\/cdn-cgi\/challenge-platform\//i,
  /window\._cf_chl_opt\b/i,
  /\bcf-browser-verification\b/i,
  /<title>\s*Attention Required! \| Cloudflare\s*<\/title>/i,
  // Akamai Bot Manager / edge block
  /<title>\s*Access Denied\s*<\/title>[\s\S]{0,2000}errors\.edgesuite\.net/i,
  /\/_sec\/cp_challenge\//i,
  // Imperva / Incapsula, DataDome, PerimeterX
  /_Incapsula_Resource/i,
  /\bgeo\.captcha-delivery\.com\b/i,
  /captcha\.px-cdn\.net/i,
];

const JS_MARKERS: readonly RegExp[] = [
  /(enable|turn on)\s+javascript/i,
  /javascript\s+is\s+(required|disabled)/i,
];

/** Visible-ish text length of an HTML string (scripts/styles/noscript/tags stripped). */
function roughTextLength(html: string): number {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<noscript[\s\S]*?<\/noscript>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim().length;
}

/**
 * "challenge" for known bot-challenge pages; "js_required" when the page asks for JavaScript and has almost no
 * text outside `<noscript>` (an SPA shell); else null.
 */
export function detectBotWall(html: string): BotWall | null {
  const head = html.length > 65_536 ? html.slice(0, 65_536) : html;
  if (CHALLENGE_MARKERS.some((re) => re.test(head))) return "challenge";
  if (JS_MARKERS.some((re) => re.test(head)) && roughTextLength(html) < 1500) return "js_required";
  return null;
}
