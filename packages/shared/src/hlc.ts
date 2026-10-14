/**
 * Client-side op timestamps. Sroka uses a simplified hybrid clock: `at` = wall-clock ms, forced to be
 * strictly increasing per device so two local edits in the same ms are ordered. The server only
 * clamps (see lww.ts clampAt); ordering ties across devices are broken by deviceId.
 */
export class OpClock {
  private last = 0;
  constructor(private readonly now: () => number = Date.now) {}

  /** Next `at` for a new local op: max(now, last + 1). */
  next(): number {
    const t = Math.max(Math.floor(this.now()), this.last + 1);
    this.last = t;
    return t;
  }

  /** Observe a remote/server time so local ops never go backwards relative to what we've seen. */
  observe(at: number): void {
    if (at > this.last) this.last = at;
  }
}
