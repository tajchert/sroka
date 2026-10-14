import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      // test/entry.ts re-exports the parser handler + LibraryDO so the LIBRARY binding (script_name sroka-api)
      // resolves to a local class; otherwise workerd fails: 'binding "LIBRARY" refers to a service "core:user:sroka-api"'.
      main: "./test/entry.ts",
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        durableObjects: { LIBRARY: { className: "LibraryDO", useSQLite: true } },
        bindings: {
          ENVIRONMENT: "development",
          APP_ORIGIN: "http://localhost:8787",
          API_ORIGIN: "http://localhost:8787",
          CONTENT_ORIGIN: "http://127.0.0.1:8787",
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
