import { describe, expect, it, vi } from "vitest";
import { checkTurnstile, isWebAppRequest } from "../src/turnstile.ts";

const env = {
  APP_ORIGIN: "https://sroka.app",
  DEV_ORIGINS: "http://localhost:5173",
  ENVIRONMENT: "production" as const,
  TURNSTILE_SECRET_KEY: "secret",
};
const URL_ = "https://api.sroka.app/api/auth/email-otp/send-verification-otp";
const req = (headers: Record<string, string>, url = URL_) => new Request(url, { method: "POST", headers });
const ok = (body: object) => vi.fn(async () => new Response(JSON.stringify(body)));

describe("turnstile", () => {
  it("passes with a valid token and sends secret/response/remoteip", async () => {
    const f = ok({ success: true, hostname: "sroka.app" });
    const r = await checkTurnstile(env, req({ origin: "https://sroka.app", "x-turnstile-token": "tok", "cf-connecting-ip": "1.2.3.4" }), f);
    expect(r).toBeNull();
    const [url, init] = f.mock.calls[0]! as unknown as [string, { body: FormData }];
    expect(url).toContain("siteverify");
    expect(init.body.get("secret")).toBe("secret");
    expect(init.body.get("response")).toBe("tok");
    expect(init.body.get("remoteip")).toBe("1.2.3.4");
  });
  it("rejects a missing token without calling siteverify", async () => {
    const f = ok({ success: true });
    expect(await checkTurnstile(env, req({ origin: "https://sroka.app" }), f)).toBe("missing_token");
    expect(f).not.toHaveBeenCalled();
  });
  it("rejects a failed verification", async () => {
    const f = ok({ success: false, "error-codes": ["invalid-input-response"] });
    expect(await checkTurnstile(env, req({ origin: "https://sroka.app", "x-turnstile-token": "t" }), f)).toBe("invalid-input-response");
  });
  it("rejects a hostname mismatch", async () => {
    const f = ok({ success: true, hostname: "evil.example" });
    expect(await checkTurnstile(env, req({ origin: "https://sroka.app", "x-turnstile-token": "t" }), f)).toBe("hostname_mismatch");
  });
  it("fails closed when siteverify is unreachable", async () => {
    const f = vi.fn(async () => {
      throw new Error("down");
    });
    expect(await checkTurnstile(env, req({ origin: "https://sroka.app", "x-turnstile-token": "t" }), f)).toBe("verify_unavailable");
  });
  it("requires a token for dev origins and for sroka.app host without Origin", async () => {
    expect(await checkTurnstile(env, req({ origin: "http://localhost:5173" }), ok({}))).toBe("missing_token");
    expect(await checkTurnstile(env, req({}, "https://sroka.app/api/auth/x"), ok({}))).toBe("missing_token");
  });
  it("exempts extension origins and api-host requests without Origin", async () => {
    const f = ok({ success: false });
    expect(await checkTurnstile(env, req({ origin: "chrome-extension://abc" }), f)).toBeNull();
    expect(await checkTurnstile(env, req({}), f)).toBeNull();
    expect(f).not.toHaveBeenCalled();
    expect(isWebAppRequest(env, req({ origin: "https://sroka.app" }))).toBe(true);
  });
  it("skips verification when no secret is configured", async () => {
    const f = ok({ success: false });
    expect(await checkTurnstile({ ...env, TURNSTILE_SECRET_KEY: undefined }, req({ origin: "https://sroka.app" }), f)).toBeNull();
    expect(f).not.toHaveBeenCalled();
  });
});
