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

/**
 * Headings (h1-h6) and anchors in document order. Linear: openers are found left to right, each closer search is
 * cached (a missing closer is remembered), and an element never extends past the next opener (unclosed tags are tolerated).
 */
export function scanBookmarks(html: string): HtmlEvent[] {
  const events: HtmlEvent[] = [];
  const lower = html.toLowerCase();
  const opener = /<(h[1-6]|a)(?=[\s>\/])/gi;
  const closeCache = new Map<string, number>();
  const findClose = (tag: string, from: number): number => {
    const cached = closeCache.get(tag);
    if (cached !== undefined && (cached === -1 || cached >= from)) return cached;
    const idx = lower.indexOf(`</${tag}`, from);
    closeCache.set(tag, idx);
    return idx;
  };
  let pos = 0;
  while (pos < html.length) {
    opener.lastIndex = pos;
    const m = opener.exec(html);
    if (!m) break;
    const tag = m[1]!.toLowerCase();
    const gt = html.indexOf(">", m.index);
    if (gt === -1) break;
    const attrs = html.slice(m.index + m[0].length, gt);
    opener.lastIndex = gt + 1;
    const nextM = opener.exec(html);
    const nextOpen = nextM ? nextM.index : html.length;
    let close = findClose(tag, gt + 1);
    let end: number;
    if (close !== -1 && close < nextOpen) {
      const cgt = html.indexOf(">", close);
      end = cgt === -1 ? html.length : cgt + 1;
    } else {
      close = nextOpen;
      end = nextOpen;
    }
    const inner = html.slice(gt + 1, close);
    if (tag === "a") events.push({ kind: "link", attrs: parseAttrs(attrs), text: textOf(inner) });
    else events.push({ kind: "heading", level: Number(tag[1]), text: textOf(inner) });
    pos = Math.max(end, gt + 1);
  }
  return events;
}
