/** Path segments that say nothing about the page (a title made of them would be useless). */
const GENERIC = new Set(["index", "amp", "article", "articles", "story", "stories", "post", "posts", "read", "view", "print", "default", "p", "a", "s"]);
const EXT = /\.(?:html?|php\d?|aspx?|jsp|shtml|xhtml|amp)$/i;

function isIdToken(t: string): boolean {
  if (/^\d+$/.test(t)) return true;
  // hex-ish ids such as "1a2b3c4d5e" (needs a digit, so plain words like "decade" survive)
  return t.length >= 6 && /^[0-9a-f]+$/i.test(t) && /\d/.test(t);
}

/**
 * Temporary title for an item whose page has not been fetched yet: the last meaningful path segment of the URL,
 * de-hyphenated and sentence-cased ("/blog/why-sqlite-is-fast.html?utm=x" → "Why sqlite is fast").
 * Ids, dates, file extensions and the query are ignored. `null` when the URL has no usable slug.
 */
export function titleFromUrl(url: string): string | null {
  let path: string;
  try {
    path = new URL(url).pathname;
  } catch {
    return null;
  }
  const segments = path.split("/").filter(Boolean);
  for (let i = segments.length - 1; i >= 0; i--) {
    let seg = segments[i]!;
    try {
      seg = decodeURIComponent(seg);
    } catch {
      /* keep the raw segment */
    }
    seg = seg.replace(EXT, "");
    const tokens = seg.split(/[-_+\s.]+/).filter(Boolean);
    while (tokens.length && isIdToken(tokens[0]!)) tokens.shift();
    while (tokens.length && isIdToken(tokens[tokens.length - 1]!)) tokens.pop();
    if (!tokens.length || GENERIC.has(tokens.join("-").toLowerCase())) continue;
    const text = tokens.join(" ");
    if (!/\p{L}{3,}/u.test(text)) continue;
    return text.charAt(0).toUpperCase() + text.slice(1);
  }
  return null;
}
