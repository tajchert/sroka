import { describe, expect, it } from "vitest";
import { call, json, migrate } from "./helpers.ts";
import { otpSink } from "../../src/email.ts";

describe("OTP per-code attempt limit (emailOTP allowedAttempts: 5)", () => {
  it("rejects the correct code after 5 wrong attempts against the same code", async () => {
    await migrate();
    const email = "attempts@example.com";
    const send = await call("/api/auth/email-otp/send-verification-otp", json({ email, type: "sign-in" }));
    expect(send.status).toBe(200);
    const otp = otpSink.get(email)!;
    expect(otp).toMatch(/^\d{6}$/);
    const wrong = otp === "000000" ? "111111" : "000000";
    for (let i = 0; i < 5; i++) {
      const res = await call("/api/auth/sign-in/email-otp", json({ email, otp: wrong }));
      expect(res.status).toBe(400);
    }
    const res = await call("/api/auth/sign-in/email-otp", json({ email, otp }));
    expect(res.status).toBe(403);
    expect(((await res.json()) as { code: string }).code).toBe("TOO_MANY_ATTEMPTS");
    expect(res.headers.get("set-auth-token")).toBeNull();
  });
});
