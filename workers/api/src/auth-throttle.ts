/**
 * Per-email OTP throttle (on top of Better Auth's per-IP rate limits): bounds how many codes one address
 * can be sent (email bombing, sending quota) and how many wrong codes can be tried against it across codes
 * and IPs (distributed brute force; each new code resets the plugin's per-code attempt counter).
 * Fixed-window counters in D1 `auth_throttle` (expired rows are deleted by the parser's weekly cron).
 */
import { APIError, createAuthMiddleware, isAPIError } from "better-auth/api";

const MIN = 60 * 1000;
const DAY = 24 * 60 * MIN;

interface Limit {
  window: number;
  max: number;
}
export const OTP_SEND_LIMITS: Limit[] = [
  { window: 15 * MIN, max: 5 },
  { window: DAY, max: 20 },
];
export const OTP_FAIL_LIMITS: Limit[] = [
  { window: 15 * MIN, max: 10 },
  { window: DAY, max: 30 },
];

/** Endpoints that email a code to `body.email`. */
const SEND_PATHS = new Set(["/email-otp/send-verification-otp", "/forget-password/email-otp", "/email-otp/request-password-reset"]);
/** Endpoints that check a code for `body.email`. */
const VERIFY_PATHS = new Set(["/sign-in/email-otp", "/email-otp/verify-email", "/email-otp/check-verification-otp", "/email-otp/reset-password"]);

function emailOf(body: unknown): string | null {
  if (!body || typeof body !== "object" || !("email" in body) || typeof body.email !== "string") return null;
  const e = body.email.trim().toLowerCase();
  return e.length > 0 && e.length <= 320 ? e : null;
}

const keyFor = (kind: string, l: Limit, email: string, now: number) => `${kind}:${l.window}:${email}:${Math.floor(now / l.window)}`;

async function counts(db: D1Database, kind: string, limits: Limit[], email: string, now: number): Promise<number[]> {
  const keys = limits.map((l) => keyFor(kind, l, email, now));
  const rows = await db
    .prepare("SELECT key, count FROM auth_throttle WHERE key IN (SELECT value FROM json_each(?1))")
    .bind(JSON.stringify(keys))
    .all<{ key: string; count: number }>();
  const m = new Map((rows.results ?? []).map((r) => [r.key, r.count]));
  return keys.map((k) => m.get(k) ?? 0);
}

async function bump(db: D1Database, kind: string, limits: Limit[], email: string, now: number): Promise<number[]> {
  const stmts = limits.map((l) =>
    db
      .prepare(
        "INSERT INTO auth_throttle (key, count, expires_at) VALUES (?1, 1, ?2) ON CONFLICT(key) DO UPDATE SET count = count + 1 RETURNING count",
      )
      .bind(keyFor(kind, l, email, now), (Math.floor(now / l.window) + 1) * l.window),
  );
  const res = await db.batch<{ count: number }>(stmts);
  return res.map((r) => r.results?.[0]?.count ?? 0);
}

function tooMany(): APIError {
  return new APIError("TOO_MANY_REQUESTS", { message: "Too many attempts for this email. Try again later." });
}

/** hooks.before: per-email send limit (counted atomically) and failed-verification lockout. */
export function otpThrottleBefore(db: D1Database, now: () => number = Date.now) {
  return createAuthMiddleware(async (ctx) => {
    const path = ctx.path ?? "";
    if (!SEND_PATHS.has(path) && !VERIFY_PATHS.has(path)) return;
    const email = emailOf(ctx.body);
    if (!email) return;
    const t = now();
    if (SEND_PATHS.has(path)) {
      const n = await bump(db, "send", OTP_SEND_LIMITS, email, t);
      if (n.some((c, i) => c > OTP_SEND_LIMITS[i]!.max)) throw tooMany();
    } else {
      const n = await counts(db, "fail", OTP_FAIL_LIMITS, email, t);
      if (n.some((c, i) => c >= OTP_FAIL_LIMITS[i]!.max)) throw tooMany();
    }
  });
}

/** hooks.after: counts failed code checks per email (across codes and IPs). */
export function otpThrottleAfter(db: D1Database, now: () => number = Date.now) {
  return createAuthMiddleware(async (ctx) => {
    if (!VERIFY_PATHS.has(ctx.path ?? "")) return;
    const email = emailOf(ctx.body);
    if (!email) return;
    const returned = ctx.context.returned;
    if (!isAPIError(returned)) return;
    const status = (returned as { statusCode?: number }).statusCode ?? 0;
    if (status === 429) return; // our own lockout
    await bump(db, "fail", OTP_FAIL_LIMITS, email, now());
  });
}
