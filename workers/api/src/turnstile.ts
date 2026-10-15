/**
 * Cloudflare Turnstile on the web sign-in "send code" step (decisions D4). Applies only to requests that come
 * from the web app (Origin = APP_ORIGIN/DEV_ORIGINS, or request host = APP_ORIGIN host). Extension / native
 * requests (other Origin or none, bearer clients) stay exempt; the per-email throttle still bounds them.
 * Skipped entirely when TURNSTILE_SECRET_KEY is unset (local dev / self-host).
 */
import { APIError, createAuthMiddleware } from "better-auth/api";
import type { Env } from "./env.ts";

export const TURNSTILE_PATH = "/email-otp/send-verification-otp";
export const TURNSTILE_HEADER = "x-turnstile-token";
const SITEVERIFY = "https://challenges.cloudflare.com/turnstile/v0/siteverify";

type TsEnv = Pick<Env, "APP_ORIGIN" | "DEV_ORIGINS" | "ENVIRONMENT" | "TURNSTILE_SECRET_KEY">;
type Fetch = (input: string, init: RequestInit) => Promise<Response>;

const hostOf = (u: string): string | null => {
  try {
    return new URL(u).host;
  } catch {
    return null;
  }
};

/**
 * True when the request comes from the web app (Turnstile required). A request without Origin counts as web only
 * when it targets the APP_ORIGIN host outside development: locally the app and the API share one host
 * (localhost:8787), and native debug clients (no Origin) must be able to sign in there.
 */
export function isWebAppRequest(env: Pick<Env, "APP_ORIGIN" | "DEV_ORIGINS" | "ENVIRONMENT">, req: Request): boolean {
  const webOrigins = [env.APP_ORIGIN, ...(env.DEV_ORIGINS ?? "").split(",").map((s) => s.trim())].filter(Boolean);
  const origin = req.headers.get("origin");
  if (origin) return webOrigins.includes(origin);
  if (env.ENVIRONMENT === "development") return false;
  const appHost = hostOf(env.APP_ORIGIN);
  return !!appHost && hostOf(req.url) === appHost;
}

/** Returns null when the request may proceed, else a short failure reason. */
export async function checkTurnstile(env: TsEnv, req: Request, fetchImpl: Fetch = fetch): Promise<string | null> {
  const secret = env.TURNSTILE_SECRET_KEY;
  if (!secret || !isWebAppRequest(env, req)) return null;
  const token = req.headers.get(TURNSTILE_HEADER);
  if (!token || token.length > 2048) return "missing_token";
  const form = new FormData();
  form.set("secret", secret);
  form.set("response", token);
  const ip = req.headers.get("cf-connecting-ip");
  if (ip) form.set("remoteip", ip);
  form.set("idempotency_key", crypto.randomUUID());
  let data: { success?: boolean; hostname?: string; "error-codes"?: string[] };
  try {
    const res = await fetchImpl(SITEVERIFY, { method: "POST", body: form });
    data = (await res.json()) as typeof data;
  } catch (e) {
    console.error("[sroka] turnstile siteverify failed", e);
    return "verify_unavailable";
  }
  if (!data.success) return (data["error-codes"] ?? ["rejected"]).join(",");
  // Test keys report a dummy hostname, so only enforce it outside development.
  if (env.ENVIRONMENT !== "development") {
    const allowed = [env.APP_ORIGIN, ...(env.DEV_ORIGINS ?? "").split(",")].map((o) => hostOf(o.trim())?.replace(/:\d+$/, ""));
    if (!data.hostname || !allowed.includes(data.hostname)) return "hostname_mismatch";
  }
  return null;
}

/** hooks.before: gate the send-code endpoint (runs before the per-email throttle so failures don't consume it). */
export function turnstileBefore(env: TsEnv, fetchImpl: Fetch = fetch) {
  return createAuthMiddleware(async (ctx) => {
    if (ctx.path !== TURNSTILE_PATH || !ctx.request) return;
    const reason = await checkTurnstile(env, ctx.request, fetchImpl);
    if (reason) {
      console.warn("[sroka] turnstile rejected:", reason);
      throw new APIError("BAD_REQUEST", { code: "TURNSTILE_FAILED", message: "Verification failed. Please try again." });
    }
  });
}
