import { forwardRef, useEffect, useImperativeHandle, useRef } from "react";

interface TurnstileApi {
  render(el: HTMLElement, opts: Record<string, unknown>): string;
  reset(id?: string): void;
  remove(id?: string): void;
}
declare global {
  interface Window {
    turnstile?: TurnstileApi;
  }
}

const SCRIPT = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
let loading: Promise<TurnstileApi> | null = null;

/** Load api.js once (explicit render). */
function loadTurnstile(): Promise<TurnstileApi> {
  if (window.turnstile) return Promise.resolve(window.turnstile);
  loading ??= new Promise<TurnstileApi>((resolve, reject) => {
    const s = document.createElement("script");
    s.src = SCRIPT;
    s.async = true;
    s.onload = () => (window.turnstile ? resolve(window.turnstile) : reject(new Error("turnstile missing")));
    s.onerror = () => {
      loading = null;
      reject(new Error("turnstile failed to load"));
    };
    document.head.appendChild(s);
  });
  return loading;
}

export interface TurnstileHandle {
  /** Tokens are single-use: call after every send attempt. */
  reset(): void;
}

/** Cloudflare Turnstile widget. `onToken(null)` when the token is cleared/expired/errored. */
export const Turnstile = forwardRef<TurnstileHandle, { siteKey: string; onToken: (t: string | null) => void }>(function Turnstile(
  { siteKey, onToken },
  ref,
) {
  const el = useRef<HTMLDivElement>(null);
  const id = useRef<string | null>(null);
  const cb = useRef(onToken);
  cb.current = onToken;

  useImperativeHandle(ref, () => ({
    reset() {
      cb.current(null);
      if (id.current && window.turnstile) window.turnstile.reset(id.current);
    },
  }));

  useEffect(() => {
    let cancelled = false;
    loadTurnstile()
      .then((ts) => {
        if (cancelled || !el.current) return;
        id.current = ts.render(el.current, {
          sitekey: siteKey,
          appearance: "interaction-only",
          theme: "auto",
          callback: (t: string) => cb.current(t),
          "expired-callback": () => cb.current(null),
          "error-callback": () => cb.current(null),
        });
      })
      .catch(() => cb.current(null));
    return () => {
      cancelled = true;
      if (id.current && window.turnstile) window.turnstile.remove(id.current);
      id.current = null;
    };
  }, [siteKey]);

  return <div ref={el} className="flex justify-center" />;
});
