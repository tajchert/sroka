import type { Env } from "./env.ts";

/** Test hook: in development the last OTP per email is recorded here (module state, same isolate as the test). */
export const otpSink = new Map<string, string>();

export async function sendOtpEmail(env: Env, email: string, otp: string, type: string): Promise<void> {
  if (env.ENVIRONMENT === "development") {
    otpSink.set(email.toLowerCase(), otp);
    console.log(`[sroka] OTP for ${email}: ${otp}`);
    return;
  }
  const subject = type === "sign-in" ? "Your Sroka sign-in code" : "Your Sroka verification code";
  await env.EMAIL.send({
    to: email,
    from: { email: "noreply@sroka.app", name: "Sroka" },
    subject,
    text: `Your Sroka code is ${otp}. It expires in 5 minutes. If you didn't request it, ignore this email.`,
    html: `<p>Your Sroka code is <b style="font-size:1.4em;letter-spacing:.1em">${otp}</b></p><p>It expires in 5 minutes. If you didn't request it, ignore this email.</p>`,
  });
}
