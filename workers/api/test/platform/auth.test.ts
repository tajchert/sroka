import { describe, expect, it } from "vitest";
import { call, json, migrate, signIn, testEnv, APP } from "./helpers.ts";
import { otpSink } from "../../src/email.ts";
import type { Env } from "../../src/env.ts";

describe("auth + /v1 middleware", () => {
  it("401 without auth", async () => {
    await migrate();
    const res = await call("/v1/me");
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: "unauthorized" });
  });

  it("health and config are public", async () => {
    expect((await call("/v1/health")).status).toBe(200);
    const res = await call("/v1/config");
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("public, max-age=300");
    const body = (await res.json()) as { appOrigin: string; features: Record<string, boolean> };
    expect(body.appOrigin).toBe(APP);
    expect(body.features.imports).toBe(true);
  });

  it("OTP flow: bearer and cookie both reach /v1/me", async () => {
    const { token, cookie } = await signIn("reader@example.com");
    const bearer = await call("/v1/me", { headers: { authorization: `Bearer ${token}` } });
    expect(bearer.status).toBe(200);
    const me = (await bearer.json()) as { user: { email: string; emailVerified: boolean; createdAt: number }; stats: object };
    expect(me.user.email).toBe("reader@example.com");
    expect(me.user.emailVerified).toBe(true);
    expect(typeof me.user.createdAt).toBe("number");
    expect(me.stats).toBeTruthy();

    const viaCookie = await call("/v1/me", { headers: { cookie } });
    expect(viaCookie.status).toBe(200);
  });

  it("wrong OTP is rejected", async () => {
    await migrate();
    await call("/api/auth/email-otp/send-verification-otp", json({ email: "bad@example.com", type: "sign-in" }));
    const res = await call("/api/auth/sign-in/email-otp", json({ email: "bad@example.com", otp: "000000" }));
    expect(res.status).toBe(400);
    expect(((await res.json()) as { code: string }).code).toBe("INVALID_OTP");
  });

  it("review account gets the fixed code", async () => {
    await migrate();
    const e = { ...testEnv, REVIEW_EMAIL: "review@example.com", REVIEW_OTP: "123456" } as Env;
    await call("/api/auth/email-otp/send-verification-otp", json({ email: "review@example.com", type: "sign-in" }), APP, e);
    expect(otpSink.get("review@example.com")).toBe("123456");
    const res = await call("/api/auth/sign-in/email-otp", json({ email: "review@example.com", otp: "123456" }), APP, e);
    expect(res.status).toBe(200);
    await call("/api/auth/email-otp/send-verification-otp", json({ email: "other@example.com", type: "sign-in" }), APP, e);
    expect(otpSink.get("other@example.com")).not.toBe("123456");
  });

  it("OTP send is rate limited to 3/min", async () => {
    await migrate();
    const h = { "cf-connecting-ip": "203.0.113.77" };
    const statuses: number[] = [];
    for (let i = 0; i < 5; i++) {
      statuses.push((await call("/api/auth/email-otp/send-verification-otp", json({ email: "rl@example.com", type: "sign-in" }, h))).status);
    }
    expect(statuses.slice(0, 3).every((s) => s === 200)).toBe(true);
    expect(statuses[4]).toBe(429);
  });

  it("per-email OTP send limit holds across IPs (email bombing)", async () => {
    await migrate();
    const statuses: number[] = [];
    for (let i = 0; i < 6; i++) {
      statuses.push((await call("/api/auth/email-otp/send-verification-otp", json({ email: "Bomb@example.com", type: "sign-in" }))).status);
    }
    expect(statuses.slice(0, 5)).toEqual([200, 200, 200, 200, 200]);
    expect(statuses[5]).toBe(429);
  });

  it("failed OTP checks are capped per email across codes and IPs", async () => {
    await migrate();
    const email = "brute@example.com";
    for (let round = 0; round < 2; round++) {
      await call("/api/auth/email-otp/send-verification-otp", json({ email, type: "sign-in" }));
      for (let i = 0; i < 5; i++) await call("/api/auth/sign-in/email-otp", json({ email, otp: "000000" }));
    }
    await call("/api/auth/email-otp/send-verification-otp", json({ email, type: "sign-in" }));
    const otp = otpSink.get(email)!;
    const res = await call("/api/auth/sign-in/email-otp", json({ email, otp }));
    expect(res.status).toBe(429); // locked out even with the right code
  });

  it("forwards the refreshed session cookie on /v1 (browser cookie keeps up with server-side expiry)", async () => {
    const { cookie } = await signIn("refresh@example.com");
    // Pretend the session was created 10 days ago (updateAge = 1 day passed).
    await testEnv.DB.prepare("UPDATE session SET expires_at = ? WHERE user_id = (SELECT id FROM user WHERE email = ?)")
      .bind(Date.now() + 80 * 86_400_000, "refresh@example.com")
      .run();
    const res = await call("/v1/me", { headers: { cookie } });
    expect(res.status).toBe(200);
    const set = res.headers.getSetCookie().find((c) => c.includes("session_token"));
    expect(set).toBeTruthy();
    expect(set).toMatch(/Max-Age=7776000/);
  });

  it("DELETE /v1/account requires confirm and removes the user", async () => {
    const { token } = await signIn("gone@example.com");
    const auth = { authorization: `Bearer ${token}`, "content-type": "application/json" };
    const bad = await call("/v1/account", { method: "DELETE", headers: auth, body: JSON.stringify({ confirm: "no" }) });
    expect(bad.status).toBe(400);
    const ok = await call("/v1/account", { method: "DELETE", headers: auth, body: JSON.stringify({ confirm: "DELETE" }) });
    expect(ok.status).toBe(200);
    expect(await ok.json()).toEqual({ deleted: true });
    expect((await call("/v1/me", { headers: auth })).status).toBe(401);
    const row = await testEnv.DB.prepare("select count(*) as n from user where email = ?").bind("gone@example.com").first<{ n: number }>();
    expect(row?.n).toBe(0);
  });
});
