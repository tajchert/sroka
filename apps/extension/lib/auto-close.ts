/**
 * Countdown that closes the saved popup. Pure timer logic (no DOM, no React) so it can be tested with fake timers.
 *
 * - `start()` begins the countdown; it runs only while nothing holds it.
 * - `hold(reason)` / `release(reason)` pause and resume it (hover, keyboard focus). Holds are a set, so hover + focus
 *   together need both to be released. Time already spent is kept, so resuming continues, it does not restart.
 * - `cancel()` stops it for good (a click, a keypress, a tag or favorite action).
 * - `dispose()` stops it silently (unmount, or the saved state went away).
 */
export type AutoCloseState = "idle" | "running" | "paused" | "cancelled" | "closed";

export type AutoClose = {
  start(): void;
  hold(reason: string): void;
  release(reason: string): void;
  cancel(): void;
  dispose(): void;
  readonly state: AutoCloseState;
};

export const AUTO_CLOSE_MS = 3000;

export function createAutoClose(opts: { ms?: number; onClose: () => void; onState?: (s: AutoCloseState) => void }): AutoClose {
  const total = opts.ms ?? AUTO_CLOSE_MS;
  const holds = new Set<string>();
  let state: AutoCloseState = "idle";
  let remaining = total;
  let startedAt = 0;
  let timer: ReturnType<typeof setTimeout> | undefined;

  const set = (s: AutoCloseState) => {
    if (s === state) return;
    state = s;
    opts.onState?.(s);
  };
  const live = () => state === "idle" || state === "running" || state === "paused";
  const stopTimer = () => {
    if (timer === undefined) return;
    clearTimeout(timer);
    timer = undefined;
    remaining = Math.max(0, remaining - (Date.now() - startedAt));
  };
  const run = () => {
    startedAt = Date.now();
    timer = setTimeout(() => {
      timer = undefined;
      remaining = 0;
      set("closed");
      opts.onClose();
    }, remaining);
    set("running");
  };

  return {
    get state() {
      return state;
    },
    start() {
      if (state !== "idle") return;
      if (holds.size) set("paused");
      else run();
    },
    hold(reason) {
      holds.add(reason);
      if (!live() || state === "idle") return;
      stopTimer();
      set("paused");
    },
    release(reason) {
      holds.delete(reason);
      if (state === "paused" && !holds.size) run();
    },
    cancel() {
      if (!live()) return;
      stopTimer();
      set("cancelled");
    },
    dispose() {
      if (!live()) return;
      stopTimer();
      state = "cancelled";
    },
  };
}

/** The countdown may run only on the saved screen and while no card waiting for an answer (consent, failed saves) shows. */
export function autoCloseWanted(s: { saved: boolean; consentShown: boolean; failedShown: boolean }): boolean {
  return s.saved && !s.consentShown && !s.failedShown;
}
