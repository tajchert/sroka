import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import worker from "../../src/index.ts";
import type { Env } from "../../src/env.ts";
import { otpSink } from "../../src/email.ts";

export const testEnv = env as unknown as Env;
export const APP = "http://localhost:8787";

const sqlFiles = (import.meta as unknown as { glob: (p: string, o: object) => Record<string, string> }).glob(
  "../../migrations/*.sql",
  { query: "?raw", import: "default", eager: true },
);

let migrated = false;
/** Apply drizzle migrations to the test D1 (idempotent per isolate). */
export async function migrate(): Promise<void> {
  if (migrated) return;
  const files = Object.keys(sqlFiles).sort();
  for (const f of files) {
    const stmts = (sqlFiles[f] as string).split("--> statement-breakpoint").map((s) => s.trim()).filter(Boolean);
    for (const s of stmts) await testEnv.DB.prepare(s).run();
  }
  migrated = true;
}

export async function call(path: string, init: RequestInit = {}, base = APP, e: Env = testEnv): Promise<Response> {
  const ctx = createExecutionContext();
  const res = await worker.fetch(new Request(base + path, init), e, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}

let ipCounter = 0;
/** JSON POST; each call gets a fresh client IP unless given, so the per-IP rate limiter doesn't couple tests. */
export function json(body: unknown, headers: Record<string, string> = {}): RequestInit {
  const ip = `10.1.${Math.floor(++ipCounter / 250)}.${ipCounter % 250}`;
  return { method: "POST", headers: { "content-type": "application/json", origin: APP, "cf-connecting-ip": ip, ...headers }, body: JSON.stringify(body) };
}

/** Full OTP sign-in; returns bearer token + cookie header. */
export async function signIn(email: string): Promise<{ token: string; cookie: string }> {
  await migrate();
  const send = await call("/api/auth/email-otp/send-verification-otp", json({ email, type: "sign-in" }));
  if (send.status !== 200) throw new Error(`send otp ${send.status} ${await send.text()}`);
  const otp = otpSink.get(email.toLowerCase());
  if (!otp) throw new Error("no otp captured");
  const res = await call("/api/auth/sign-in/email-otp", json({ email, otp }));
  if (res.status !== 200) throw new Error(`sign-in ${res.status} ${await res.text()}`);
  const token = res.headers.get("set-auth-token");
  if (!token) throw new Error("no set-auth-token");
  const cookie = res.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
  return { token, cookie };
}
