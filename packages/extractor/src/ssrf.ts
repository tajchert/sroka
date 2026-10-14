/** SSRF guard: URL / host validation for outbound fetches (defense in depth; Workers also can't reach private nets). */

export class BlockedUrlError extends Error {
  constructor(public reason: string) {
    super(`blocked_url: ${reason}`);
  }
}

function parseIPv4(host: string): number[] | null {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!m) return null;
  const p = m.slice(1).map(Number);
  return p.every((n) => n <= 255) ? p : null;
}

export function isPrivateIPv4(p: number[]): boolean {
  const [a, b, c] = p as [number, number, number, number];
  return (
    a === 0 || // "this" network
    a === 10 ||
    a === 127 ||
    (a === 100 && b >= 64 && b <= 127) || // CGNAT
    (a === 169 && b === 254) || // link-local / metadata
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 0 && c === 0) || // IETF protocol assignments
    (a === 192 && b === 0 && c === 2) || // TEST-NET-1
    (a === 192 && b === 168) ||
    (a === 198 && (b === 18 || b === 19)) || // benchmarking
    (a === 198 && b === 51 && c === 100) ||
    (a === 203 && b === 0 && c === 113) ||
    a >= 224 // multicast, reserved, broadcast
  );
}

/** Expand an IPv6 literal (no brackets) to 8 16-bit groups, or null if malformed. */
function parseIPv6(host: string): number[] | null {
  let h = host.split("%")[0]!;
  const lastColon = h.lastIndexOf(":");
  const tail = h.slice(lastColon + 1);
  if (tail.includes(".")) {
    const v4 = parseIPv4(tail);
    if (!v4) return null;
    h = h.slice(0, lastColon + 1) + ((v4[0]! << 8) | v4[1]!).toString(16) + ":" + ((v4[2]! << 8) | v4[3]!).toString(16);
  }
  const halves = h.split("::");
  if (halves.length > 2) return null;
  const toGroups = (s: string) => (s === "" ? [] : s.split(":"));
  const head = toGroups(halves[0]!);
  const rest = halves.length === 2 ? toGroups(halves[1]!) : [];
  let groups: string[];
  if (halves.length === 2) {
    const fill = 8 - head.length - rest.length;
    if (fill < 1) return null;
    groups = [...head, ...Array<string>(fill).fill("0"), ...rest];
  } else groups = head;
  if (groups.length !== 8) return null;
  const out: number[] = [];
  for (const g of groups) {
    if (!/^[0-9a-fA-F]{1,4}$/.test(g)) return null;
    out.push(parseInt(g, 16));
  }
  return out;
}

export function isPrivateIPv6(g: number[]): boolean {
  const [g0, g1, g2, g3, g4, g5, g6, g7] = g as [number, number, number, number, number, number, number, number];
  const v4 = [g6 >> 8, g6 & 255, g7 >> 8, g7 & 255];
  if (g.every((x) => x === 0)) return true; // ::
  if (g0 === 0 && g1 === 0 && g2 === 0 && g3 === 0 && g4 === 0 && g5 === 0 && g6 === 0 && g7 === 1) return true; // ::1
  // IPv4-mapped ::ffff:a.b.c.d and IPv4-compatible ::a.b.c.d
  if (g0 === 0 && g1 === 0 && g2 === 0 && g3 === 0 && g4 === 0 && (g5 === 0xffff || g5 === 0)) return isPrivateIPv4(v4);
  // SIIT ::ffff:0:a.b.c.d
  if (g0 === 0 && g1 === 0 && g2 === 0 && g3 === 0 && g4 === 0xffff && g5 === 0) return isPrivateIPv4(v4);
  // NAT64 64:ff9b::/96 and local-use 64:ff9b:1::/48
  if (g0 === 0x64 && g1 === 0xff9b) return g2 === 1 || (g2 === 0 && g3 === 0 && g4 === 0 && g5 === 0 && isPrivateIPv4(v4));
  // 6to4 2002:AABB:CCDD::/48 embeds an IPv4
  if (g0 === 0x2002) return isPrivateIPv4([g1 >> 8, g1 & 255, g2 >> 8, g2 & 255]);
  if ((g0 & 0xfe00) === 0xfc00) return true; // fc00::/7 ULA
  if ((g0 & 0xffc0) === 0xfe80) return true; // fe80::/10 link-local
  if ((g0 & 0xffc0) === 0xfec0) return true; // fec0::/10 site-local (deprecated)
  if ((g0 & 0xff00) === 0xff00) return true; // multicast
  if (g0 === 0x2001 && g1 === 0xdb8) return true; // documentation
  if (g0 === 0x2001 && g1 === 0) return true; // Teredo
  return false;
}

/** true if `hostname` (as in URL.hostname: lower-case, IPv6 in brackets) must not be fetched. */
export function isBlockedHost(hostname: string, ownHosts: readonly string[] = []): boolean {
  let h = hostname.toLowerCase();
  if (h.endsWith(".")) h = h.replace(/\.+$/, "");
  if (h === "") return true;
  if (h.startsWith("[") && h.endsWith("]")) {
    const g = parseIPv6(h.slice(1, -1));
    return g === null || isPrivateIPv6(g);
  }
  const v4 = parseIPv4(h);
  if (v4) return isPrivateIPv4(v4);
  // Non-canonical numeric hosts (URL() normalizes these; refuse leftovers)
  if (/^(0x[0-9a-f]*|\d+)(\.(0x[0-9a-f]*|\d+))*$/i.test(h)) return true;
  if (h === "localhost" || h.endsWith(".localhost")) return true;
  if (h.endsWith(".local") || h.endsWith(".internal") || h.endsWith(".home.arpa") || h.endsWith(".lan") || h.endsWith(".intranet")) return true;
  if (!h.includes(".")) return true; // single-label intranet names
  for (const own of ownHosts) {
    const o = own.toLowerCase().replace(/\.$/, "");
    if (o && (h === o || h.endsWith("." + o))) return true;
  }
  return false;
}

/** Parse + validate a URL for outbound fetch. Throws BlockedUrlError. */
export function assertFetchable(raw: string | URL, ownHosts: readonly string[] = []): URL {
  let u: URL;
  try {
    u = raw instanceof URL ? raw : new URL(raw);
  } catch {
    throw new BlockedUrlError("invalid_url");
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") throw new BlockedUrlError("scheme");
  if (u.username || u.password) throw new BlockedUrlError("userinfo");
  if (isBlockedHost(u.hostname, ownHosts)) throw new BlockedUrlError("host");
  return u;
}
