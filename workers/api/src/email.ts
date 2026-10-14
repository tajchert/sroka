import { hashId, log, maskEmail, writeMetric } from "@sroka/shared";
import type { Env } from "./env.ts";

/** Test hook: in development the last OTP per email is recorded here (module state, same isolate as the test). */
export const otpSink = new Map<string, string>();

export async function sendOtpEmail(env: Env, email: string, otp: string, type: string): Promise<void> {
  if (env.ENVIRONMENT === "development") {
    otpSink.set(email.toLowerCase(), otp);
    // DEV ONLY (ENVIRONMENT=development; used by scripts/e2e-local.sh): the one place an OTP is printed.
    console.log(`[sroka] OTP for ${email}: ${otp}`);
    return;
  }
  const subject = type === "sign-in" ? "Your Sroka sign-in code" : "Your Sroka verification code";
  try {
    await sendEmail(env, email, subject, otp);
    writeMetric(env.METRICS, { event: "otp_send", blobs: [type, "ok"] });
  } catch (e) {
    log.exception("otp email send failed", e, { event: "otp_send_failed", otpType: type, emailMasked: maskEmail(email), emailHash: await hashId(email.toLowerCase()) });
    writeMetric(env.METRICS, { event: "otp_send", blobs: [type, "failed"] });
    throw e;
  }
}

async function sendEmail(env: Env, email: string, subject: string, otp: string): Promise<void> {
  await env.EMAIL.send({
    to: email,
    from: { email: "noreply@sroka.app", name: "Sroka" },
    subject,
    text: `Your Sroka code is ${otp}. It expires in 5 minutes. If you didn't request it, ignore this email.`,
    html: `<p>Your Sroka code is <b style="font-size:1.4em;letter-spacing:.1em">${otp}</b></p><p>It expires in 5 minutes. If you didn't request it, ignore this email.</p>`,
  });
}
