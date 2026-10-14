/**
 * Per-field last-writer-wins (design §8.4, decisions D5).
 *
 * A stamp is (at, deviceId). Stamp A beats B iff A.at > B.at, or A.at == B.at and A.dev > B.dev
 * (plain string comparison). Equal stamps (same at and device) → the later-applied op wins
 * (so a device re-sending a newer value with the same ms still converges).
 * Server clamps `at` to now + 5 min before comparing/storing.
 */
import { LIMITS } from "./limits.ts";

export interface Stamp {
  at: number;
  dev: string;
}

/** Fields with independent LWW clocks on an item. `progress` covers progress + progressAnchor + lastReadAt. */
export const LWW_FIELDS = ["title", "status", "isFavorite", "progress"] as const;
export type LwwField = (typeof LWW_FIELDS)[number];

/** JSON stored in items.clock. Missing field = never written (any stamp wins). */
export type ItemClock = Partial<Record<LwwField, Stamp>>;

export function clampAt(at: number, now: number = Date.now()): number {
  return Math.min(at, now + LIMITS.maxClockSkewMs);
}

/** -1 if a < b, 0 if equal, 1 if a > b. */
export function compareStamps(a: Stamp, b: Stamp): -1 | 0 | 1 {
  if (a.at !== b.at) return a.at > b.at ? 1 : -1;
  if (a.dev !== b.dev) return a.dev > b.dev ? 1 : -1;
  return 0;
}

/** True if `incoming` should overwrite a value stamped `current` (undefined = never written). */
export function lwwWins(incoming: Stamp, current: Stamp | undefined): boolean {
  return current === undefined || compareStamps(incoming, current) >= 0;
}

/**
 * If `incoming` wins for `field`, records it in `clock` (mutating) and returns true.
 * Use: `if (applyLww(clock, "status", s)) { …write column… }`.
 */
export function applyLww(clock: ItemClock, field: LwwField, incoming: Stamp): boolean {
  if (!lwwWins(incoming, clock[field])) return false;
  clock[field] = { at: incoming.at, dev: incoming.dev };
  return true;
}

/**
 * item_tags pair LWW (D5): same rule as item fields — stamp `{at, dev}` stored in item_tags.at/.dev.
 * `current` undefined = pair never written.
 */
export function pairWins(incoming: Stamp, current: Stamp | undefined): boolean {
  return lwwWins(incoming, current);
}

export function parseClock(json: string | null | undefined): ItemClock {
  if (!json) return {};
  try {
    const v = JSON.parse(json) as unknown;
    return v && typeof v === "object" ? (v as ItemClock) : {};
  } catch {
    return {};
  }
}
