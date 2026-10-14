/**
 * UUIDv7 (RFC 9562): 48-bit unix ms timestamp, version 7, 12-bit rand_a, variant, 62-bit rand_b.
 * Monotonic within a process: when called twice in the same millisecond, rand_a is used as a counter
 * (incremented); on counter overflow the timestamp is advanced by 1 ms. Strings therefore sort
 * lexicographically in creation order. Uses WebCrypto (works in Workers, browsers, Node ≥ 20).
 */

let lastMs = -1;
let counter = 0; // 12-bit rand_a

function randomBytes(n: number): Uint8Array {
  const b = new Uint8Array(n);
  crypto.getRandomValues(b);
  return b;
}

const HEX: string[] = Array.from({ length: 256 }, (_, i) => i.toString(16).padStart(2, "0"));

export function uuidv7(now: number = Date.now()): string {
  let ms = Math.floor(now);
  if (ms <= lastMs) {
    ms = lastMs;
    counter++;
    if (counter > 0xfff) {
      ms = lastMs + 1;
      counter = randomBytes(2).reduce((a, b) => (a << 8) | b, 0) & 0x7ff; // leave headroom
    }
  } else {
    // fresh millisecond: random start in the lower half so increments rarely overflow
    counter = randomBytes(2).reduce((a, b) => (a << 8) | b, 0) & 0x7ff;
  }
  lastMs = ms;

  const b = randomBytes(16);
  // 48-bit big-endian timestamp
  b[0] = Math.floor(ms / 2 ** 40) & 0xff;
  b[1] = Math.floor(ms / 2 ** 32) & 0xff;
  b[2] = (ms >>> 24) & 0xff;
  b[3] = (ms >>> 16) & 0xff;
  b[4] = (ms >>> 8) & 0xff;
  b[5] = ms & 0xff;
  // version 7 + 12-bit counter
  b[6] = 0x70 | ((counter >>> 8) & 0x0f);
  b[7] = counter & 0xff;
  // variant 10xx
  b[8] = 0x80 | (b[8]! & 0x3f);

  let s = "";
  for (let i = 0; i < 16; i++) {
    s += HEX[b[i]!];
    if (i === 3 || i === 5 || i === 7 || i === 9) s += "-";
  }
  return s;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** Any RFC 9562 UUID (versions 1–8). */
export function isUuid(s: unknown): s is string {
  return typeof s === "string" && UUID_RE.test(s);
}

/** Extracts the unix-ms timestamp from a UUIDv7 (undefined if not a v7). */
export function uuidv7Time(id: string): number | undefined {
  if (!isUuid(id) || id[14] !== "7") return undefined;
  return parseInt(id.slice(0, 8) + id.slice(9, 13), 16);
}
