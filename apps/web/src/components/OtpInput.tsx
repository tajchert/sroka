import { forwardRef, useState } from "react";
import "./otp.css";

export const OTP_LENGTH = 6;

/** Digits only, at most 6: "123 456", "123-456" and "123456 " all become a plain code. */
export const cleanOtp = (raw: string) => raw.replace(/\D/g, "").slice(0, OTP_LENGTH);

interface Props {
  value: string;
  onChange: (value: string) => void;
  /** Called when a change leaves a complete, different code (typing or paste). */
  onComplete?: (value: string) => void;
  /** Accessible name of the field, e.g. "Code sent to you@example.com". */
  label: string;
  /** Read-only while a check is running (keeps focus, unlike `disabled`). */
  busy?: boolean;
  invalid?: boolean;
  /** Id of the element describing the field (the error message). */
  describedBy?: string;
}

/**
 * Six visual boxes painted under ONE real input, so paste, autofill (`one-time-code`) and screen readers
 * behave like a normal field. No `maxLength` on the input: it would cut a pasted "123 456" before
 * `onChange` can strip the separator.
 */
export const OtpInput = forwardRef<HTMLInputElement, Props>(function OtpInput(
  { value, onChange, onComplete, label, busy, invalid, describedBy },
  ref,
) {
  const [focus, setFocus] = useState(false);
  const accept = (raw: string) => {
    const next = cleanOtp(raw);
    onChange(next);
    if (next.length === OTP_LENGTH && next !== value) onComplete?.(next);
  };
  return (
    <div className="otp">
      <div className="otp-boxes" aria-hidden="true">
        {Array.from({ length: OTP_LENGTH }, (_, i) => {
          const active = focus && !busy && i === Math.min(value.length, OTP_LENGTH - 1);
          const state = invalid ? "is-error" : active ? "is-active" : value[i] ? "is-filled" : "";
          return (
            <span key={i} data-testid="otp-box" className={`otp-box ${state}`}>
              {value[i] ?? ""}
            </span>
          );
        })}
      </div>
      <input
        ref={ref}
        className="otp-input"
        aria-label={label}
        aria-invalid={invalid || undefined}
        aria-describedby={describedBy}
        inputMode="numeric"
        autoComplete="one-time-code"
        pattern="[0-9]*"
        autoFocus
        value={value}
        readOnly={busy}
        onFocus={() => setFocus(true)}
        onBlur={() => setFocus(false)}
        onChange={(e) => accept(e.target.value)}
      />
    </div>
  );
});
