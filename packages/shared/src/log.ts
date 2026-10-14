/**
 * Structured JSON logger shared by the Workers (runtime-neutral: console + WebCrypto only).
 * One JSON object per line; Workers Logs indexes the top-level fields (level, msg, event, requestId, ...).
 * Never pass secrets/OTPs/cookies/article content; as a safety net sensitive keys are redacted and emails masked.
 * See docs/observability.md.
 */
export type LogLevel = "debug" | "info" | "warn" | "error";

export interface LogFields {
  /** Machine-readable event name, e.g. "http_request", "parse", "otp_send_failed". */
  event?: string;
  requestId?: string;
  userHash?: string;
  [key: string]: unknown;
}

const SENSITIVE_KEY = /secret|token|password|passwd|cookie|authorization|api[-_]?key|signature|^otp$|^html$|^content$|^body$|^text$|^code$/i;
const EMAIL_KEY = /email/i;
const EMAIL_RE = /[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})/g;
const BEARER_RE = /Bearer\s+[A-Za-z0-9._~+/=-]+/gi;
const MAX_STR = 2000;

/** `jane.doe@example.com` -> `j***@example.com`. */
export function maskEmail(email: string): string {
  const at = email.lastIndexOf("@");
  if (at < 1) return email.slice(0, 1) + "***";
  return `${email[0]}***${email.slice(at)}`;
}

/** SHA-256 hex prefix (default 12 chars) — stable pseudonymous id for users/emails in logs. */
export async function hashId(value: string, len = 12): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  let hex = "";
  for (const b of new Uint8Array(buf)) hex += b.toString(16).padStart(2, "0");
  return hex.slice(0, len);
}

function scrubString(s: string): string {
  const out = s.replace(BEARER_RE, "Bearer [redacted]").replace(EMAIL_RE, (m) => maskEmail(m));
  return out.length > MAX_STR ? `${out.slice(0, MAX_STR)}…[truncated]` : out;
}

function sanitize(v: unknown, key: string, depth: number): unknown {
  if (key && SENSITIVE_KEY.test(key)) return "[redacted]";
  if (typeof v === "string") return key && EMAIL_KEY.test(key) ? maskEmail(v) : scrubString(v);
  if (v === null || typeof v === "number" || typeof v === "boolean" || v === undefined) return v;
  if (typeof v === "bigint") return v.toString();
  if (v instanceof Error) return errorFields(v);
  if (depth >= 4) return "[depth]";
  if (Array.isArray(v)) return v.slice(0, 50).map((x) => sanitize(x, "", depth + 1));
  if (typeof v === "object") {
    const o: Record<string, unknown> = {};
    for (const [k, x] of Object.entries(v as Record<string, unknown>)) o[k] = sanitize(x, k, depth + 1);
    return o;
  }
  return String(v);
}

/** `{errName, errMessage, stack}` for any thrown value. */
export function errorFields(e: unknown): { errName: string; errMessage: string; stack?: string } {
  if (e instanceof Error) {
    return {
      errName: e.name,
      errMessage: scrubString(e.message),
      ...(e.stack ? { stack: scrubString(e.stack) } : {}),
    };
  }
  return { errName: "NonError", errMessage: scrubString(String(e)) };
}

/** Builds the sanitized record (exported for tests). */
export function buildRecord(level: LogLevel, msg: string, fields: LogFields = {}): Record<string, unknown> {
  const rec: Record<string, unknown> = { level, msg: scrubString(msg) };
  for (const [k, v] of Object.entries(fields)) {
    if (k === "level" || k === "msg") continue;
    rec[k] = sanitize(v, k, 0);
  }
  return rec;
}

function emit(level: LogLevel, msg: string, fields?: LogFields): void {
  let line: string;
  try {
    line = JSON.stringify(buildRecord(level, msg, fields));
  } catch {
    line = JSON.stringify({ level, msg: "log_serialization_failed" });
  }
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.log(line);
}

export const log = {
  debug: (msg: string, fields?: LogFields) => emit("debug", msg, fields),
  info: (msg: string, fields?: LogFields) => emit("info", msg, fields),
  warn: (msg: string, fields?: LogFields) => emit("warn", msg, fields),
  error: (msg: string, fields?: LogFields) => emit("error", msg, fields),
  /** error-level line from a caught value: `log.exception("op failed", e, {event})`. */
  exception: (msg: string, e: unknown, fields?: LogFields) => emit("error", msg, { ...fields, ...errorFields(e) }),
  /** warn-level variant of exception. */
  warnException: (msg: string, e: unknown, fields?: LogFields) => emit("warn", msg, { ...fields, ...errorFields(e) }),
};
