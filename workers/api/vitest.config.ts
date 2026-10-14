import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.jsonc" } })],
  test: {
    // vitest 5 fs module cache breaks @cloudflare/vitest-plugin 1.4.x ("no such file … .vitest-cache").
    fsModuleCache: false,
    include: ["test/**/*.test.ts", "src/**/*.test.ts"] },
});
