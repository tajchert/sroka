/**
 * FTS5 MATCH expression from user input (api.md §5.2): each whitespace-separated term is quoted and
 * prefix-matched (`"term"*`), terms ANDed. Terms without any letter/digit are dropped (they tokenize to
 * nothing and would make an empty phrase). Returns null when nothing searchable is left.
 */
export function buildMatchQuery(q: string): string | null {
  const terms = q
    .normalize("NFC")
    .split(/\s+/)
    .filter((t) => /[\p{L}\p{N}]/u.test(t))
    .slice(0, 32);
  if (terms.length === 0) return null;
  return terms.map((t) => `"${t.replace(/"/g, '""')}"*`).join(" ");
}

/** Normalizes the `domain` list filter: lower-case host, leading "www." and trailing dots removed. */
export function normalizeDomainFilter(d: string): string {
  let s = d.trim().toLowerCase();
  // Accept a pasted URL too.
  if (/^[a-z][a-z0-9+.-]*:\/\//.test(s)) {
    try {
      s = new URL(s).hostname;
    } catch {
      /* keep as is */
    }
  }
  s = s.replace(/\.+$/, "").replace(/^www\./, "");
  // Stored domains come from the canonical URL (WHATWG host: punycode for IDNs) → convert the filter the same way.
  if (s !== "" && /[^\x00-\x7f]/.test(s)) {
    try {
      s = new URL("http://" + s).hostname;
    } catch {
      /* keep as is */
    }
  }
  return s;
}

/** Escapes LIKE wildcards (ESCAPE '\'). */
export function escapeLike(s: string): string {
  return s.replace(/[\\%_]/g, (c) => "\\" + c);
}
