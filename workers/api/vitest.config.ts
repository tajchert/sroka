import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      // wrangler.jsonc vars are production and .dev.vars is gitignored → test-only overrides (D4 console OTP path).
      miniflare: {
        bindings: {
          ENVIRONMENT: "development",
          TURNSTILE_SITE_KEY: "1x00000000000000000000AA", // site key only; secret unset => verification skipped
          // Explicitly empty: otherwise a local .dev.vars (npm run dev:setup) leaks its test secret in and every OTP send fails.
          TURNSTILE_SECRET_KEY: "",
          APP_ORIGIN: "http://localhost:8787",
          API_ORIGIN: "http://localhost:8787",
          CONTENT_ORIGIN: "http://127.0.0.1:8787",
          DEV_ORIGINS: "http://localhost:5173",
          BETTER_AUTH_SECRET: "test-secret-0123456789abcdef0123456789",
          CONTENT_URL_SIGNING_KEY: "test-signing-0123456789abcdef0123456789",
        },
      },
    }),
  ],
  test: {
    // vitest 5 fs module cache breaks @cloudflare/vitest-plugin 1.4.x ("no such file … .vitest-cache").
    fsModuleCache: false,
    include: ["test/**/*.test.ts", "src/**/*.test.ts"] },
});
