import { useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";
import { LogoMark } from "../components/Logo.tsx";
import { ApiRequestError, api, describeAuthError } from "../lib/api.ts";

export default function SignIn() {
  const qc = useQueryClient();
  const [step, setStep] = useState<"email" | "code">("email");
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [wait, setWait] = useState(0);
  const codeRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (wait <= 0) return;
    const t = setTimeout(() => setWait((w) => w - 1), 1000);
    return () => clearTimeout(t);
  }, [wait]);
  useEffect(() => {
    if (step === "code") codeRef.current?.focus();
  }, [step]);

  const fail = (e: unknown) => {
    setError(describeAuthError(e));
    if (e instanceof ApiRequestError && e.status === 429 && e.retryAfter) setWait(Math.ceil(e.retryAfter));
  };

  const sendCode = async () => {
    setBusy(true);
    setError(null);
    try {
      await api.sendOtp(email.trim());
      setStep("code");
      setCode("");
    } catch (e) {
      fail(e);
    } finally {
      setBusy(false);
    }
  };

  const verify = async (value: string) => {
    setBusy(true);
    setError(null);
    try {
      await api.verifyOtp(email.trim(), value);
      await qc.invalidateQueries({ queryKey: ["me"] });
    } catch (e) {
      fail(e);
      setCode("");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="flex min-h-full items-center justify-center px-6 py-12">
      <div className="w-full max-w-sm">
        <div className="mb-8 flex items-center gap-3">
          <LogoMark size={40} />
          <h1 className="font-serif text-3xl font-semibold tracking-tight">Sign in to Sroka</h1>
        </div>

        {step === "email" ? (
          <form
            onSubmit={(e) => {
              e.preventDefault();
              void sendCode();
            }}
            className="flex flex-col gap-3"
          >
            <label htmlFor="email" className="text-sm text-ink2">
              Enter your email and we will send you a 6-digit code. No password needed.
            </label>
            <input id="email" className="input" type="email" autoComplete="email" required autoFocus value={email} onChange={(e) => setEmail(e.target.value)} placeholder="you@example.com" />
            <button className="btn btn-primary" disabled={busy || wait > 0 || !email}>
              {busy ? "Sending" : wait > 0 ? `Wait ${wait}s` : "Email me a code"}
            </button>
          </form>
        ) : (
          <form
            onSubmit={(e) => {
              e.preventDefault();
              if (code.length === 6) void verify(code);
            }}
            className="flex flex-col gap-3"
          >
            <label htmlFor="code" className="text-sm text-ink2">
              We sent a code to <strong className="text-ink">{email}</strong>. It expires in 5 minutes.
            </label>
            <input
              id="code"
              ref={codeRef}
              className="input text-center font-mono text-2xl tracking-[0.5em]"
              inputMode="numeric"
              autoComplete="one-time-code"
              pattern="[0-9]{6}"
              maxLength={6}
              value={code}
              onChange={(e) => {
                const v = e.target.value.replace(/\D/g, "").slice(0, 6);
                setCode(v);
                if (v.length === 6 && !busy) void verify(v);
              }}
              placeholder="000000"
            />
            <button className="btn btn-primary" disabled={busy || code.length !== 6}>
              {busy ? "Checking" : "Sign in"}
            </button>
            <div className="flex justify-between text-sm">
              <button type="button" className="cursor-pointer text-ink2 hover:text-ink hover:underline" onClick={() => { setStep("email"); setError(null); }}>
                Use a different email
              </button>
              <button type="button" className="cursor-pointer text-ink2 hover:text-ink hover:underline disabled:opacity-50" disabled={busy || wait > 0} onClick={() => void sendCode()}>
                {wait > 0 ? `Resend in ${wait}s` : "Send a new code"}
              </button>
            </div>
          </form>
        )}
        {error && (
          <p role="alert" className="mt-4 text-sm text-[#c2362f]">
            {error}
          </p>
        )}
        <p className="mt-10 text-xs text-ink2">
          New here? Signing in creates your account. <a className="underline" href="/">About Sroka</a>
        </p>
      </div>
    </div>
  );
}
