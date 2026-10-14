/** Tiny tolerant scanner for Pocket / Netscape bookmark HTML (no DOM; handles unclosed <DT>/<DD>). */

const NAMED: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };

export function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (m, e: string) => {
    if (e[0] === "#") {
      const cp = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      try {
        return Number.isFinite(cp) ? String.fromCodePoint(cp) : m;
      } catch {
        return m;
      }
    }
    return NAMED[e.toLowerCase()] ?? m;
  });
}

function textOf(html: string): string {
  return decodeEntities(html.replace(/<[^>]*>/g, "")).replace(/\s+/g, " ").trim();
}

function parseAttrs(s: string): Record<string, string> {
  const out: Record<string, string> = {};
  const re = /([^\s=\/"'<>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g;
  for (let m = re.exec(s); m; m = re.exec(s)) {
    out[m[1]!.toLowerCase()] = decodeEntities(m[2] ?? m[3] ?? m[4] ?? "");
  }
  return out;
}

export type HtmlEvent =
  | { kind: "heading"; level: number; text: string }
  | { kind: "link"; attrs: Record<string, string>; text: string };

/** Headings (h1-h6) and anchors in document order. */
export function scanBookmarks(html: string): HtmlEvent[] {
  const events: HtmlEvent[] = [];
  const re = /<(h[1-6])\b[^>]*>([\s\S]*?)<\/\1\s*>|<a\b([^>]*)>([\s\S]*?)<\/a\s*>/gi;
  for (let m = re.exec(html); m; m = re.exec(html)) {
    if (m[1]) events.push({ kind: "heading", level: Number(m[1][1]), text: textOf(m[2]!) });
    else events.push({ kind: "link", attrs: parseAttrs(m[3]!), text: textOf(m[4]!) });
  }
  return events;
}
