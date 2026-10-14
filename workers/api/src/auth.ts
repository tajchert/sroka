import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { bearer, emailOTP } from "better-auth/plugins";
import { drizzle } from "drizzle-orm/d1";
import type { Env } from "./env.ts";
import * as schema from "./db/auth-schema.ts";
import { sendOtpEmail } from "./email.ts";

export type WaitUntil = { waitUntil(p: Promise<unknown>): void };

/** Parse DEV_ORIGINS (comma-separated) into a clean list. */
export function devOrigins(env: Pick<Env, "DEV_ORIGINS">): string[] {
  return (env.DEV_ORIGINS ?? "").split(",").map((s) => s.trim()).filter(Boolean);
}

function randomOtp(len: number): string {
  const buf = new Uint32Array(len);
  crypto.getRandomValues(buf);
  return Array.from(buf, (n) => String(n % 10)).join("");
}

/** Per-request Better Auth instance (decisions D4). Never cache module-global. */
export function createAuth(env: Env, ctx?: WaitUntil) {
  const db = drizzle(env.DB, { schema });
  const dev = env.ENVIRONMENT === "development";
  const trustedOrigins = [
    env.APP_ORIGIN,
    env.API_ORIGIN,
    ...(env.EXT_ID ? [`chrome-extension://${env.EXT_ID}`] : []),
    ...(dev ? ["chrome-extension://*"] : []),
    ...devOrigins(env),
  ];
  const reviewEmail = env.REVIEW_EMAIL?.trim().toLowerCase();
  const reviewOtp = env.REVIEW_OTP;
  return betterAuth({
    baseURL: env.API_ORIGIN,
    secret: env.BETTER_AUTH_SECRET,
    database: drizzleAdapter(db, { provider: "sqlite", schema }),
    trustedOrigins,
    session: {
      expiresIn: 60 * 60 * 24 * 90,
      updateAge: 60 * 60 * 24,
    },
    rateLimit: {
      enabled: true,
      window: 60,
      max: 100,
      storage: "database",
      customRules: {
        "/email-otp/send-verification-otp": { window: 60, max: 3 },
      },
    },
    advanced: {
      ipAddress: { ipAddressHeaders: ["cf-connecting-ip", "x-forwarded-for"] },
      defaultCookieAttributes: { sameSite: "lax", secure: !dev, httpOnly: true },
    },
    plugins: [
      bearer(),
      emailOTP({
        otpLength: 6,
        expiresIn: 300,
        allowedAttempts: 5,
        storeOTP: "hashed",
        ...(reviewEmail && reviewOtp
          ? {
              generateOTP: ({ email }: { email: string }) =>
                email.trim().toLowerCase() === reviewEmail ? reviewOtp : randomOtp(6),
            }
          : {}),
        async sendVerificationOTP({ email, otp, type }) {
          const p = sendOtpEmail(env, email, otp, type).catch((e) => console.error("[sroka] OTP email failed", e));
          if (ctx) ctx.waitUntil(p);
          else await p;
        },
      }),
    ],
  });
}

export type Auth = ReturnType<typeof createAuth>;
