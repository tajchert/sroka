import { describe, expect, it } from "vitest";
import { call, json, migrate, testEnv } from "./helpers.ts";

const PATH = "/api/auth/email-otp/send-verification-otp";

describe("turnstile hook (Better Auth)", () => {
  it("400 TURNSTILE_FAILED for the web app without a token when a secret is set", async () => {
    await migrate();
    const e = { ...testEnv, TURNSTILE_SECRET_KEY: "secret" };
    const res = await call(PATH, json({ email: "ts@example.com", type: "sign-in" }), undefined, e);
    expect(res.status).toBe(400);
    expect(((await res.json()) as { code: string }).code).toBe("TURNSTILE_FAILED");
  });
  it("extension origin is exempt", async () => {
    await migrate();
    const e = { ...testEnv, TURNSTILE_SECRET_KEY: "secret" };
    const res = await call(PATH, json({ email: "ts2@example.com", type: "sign-in" }, { origin: "chrome-extension://abc" }), undefined, e);
    expect(res.status).toBe(200);
  });
  it("no secret: web app sends without a token", async () => {
    await migrate();
    const res = await call(PATH, json({ email: "ts3@example.com", type: "sign-in" }));
    expect(res.status).toBe(200);
  });
});
