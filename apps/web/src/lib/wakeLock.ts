import { useEffect, useState } from "react";

/** Idle time (no reading activity) after which the screen may sleep again. */
export const WAKE_IDLE_MS = 5 * 60_000;

/**
 * Keeps the screen on while [enabled] and [activity] changed within [idleMs] (Screen Wake Lock API).
 * The browser drops the lock when the tab is hidden; it is taken again when the tab comes back.
 * A no-op where the API is missing or the request is refused (insecure origin, battery saver).
 */
export function useScreenWakeLock(enabled: boolean, activity: unknown, idleMs: number = WAKE_IDLE_MS): void {
  const [awake, setAwake] = useState(true);
  useEffect(() => {
    setAwake(true);
    const t = setTimeout(() => setAwake(false), idleMs);
    return () => clearTimeout(t);
  }, [activity, idleMs]);

  const active = enabled && awake;
  useEffect(() => {
    if (!active || typeof navigator === "undefined" || !("wakeLock" in navigator)) return;
    let lock: WakeLockSentinel | null = null;
    let cancelled = false;
    const acquire = () => {
      if (document.visibilityState !== "visible" || (lock && !lock.released)) return;
      navigator.wakeLock.request("screen").then(
        (l) => {
          if (cancelled) void l.release().catch(() => undefined);
          else lock = l;
        },
        () => undefined,
      );
    };
    acquire();
    document.addEventListener("visibilitychange", acquire);
    return () => {
      cancelled = true;
      document.removeEventListener("visibilitychange", acquire);
      void lock?.release().catch(() => undefined);
    };
  }, [active]);
}
