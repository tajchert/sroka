import { resolve } from "node:path";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

// Multi-page build (decisions D8): index.html = landing at "/", app/index.html = SPA at "/app/".
export default defineConfig({
  plugins: [react(), tailwindcss()],
  build: {
    outDir: "dist",
    rollupOptions: {
      input: {
        landing: resolve(import.meta.dirname, "index.html"),
        app: resolve(import.meta.dirname, "app/index.html"),
      },
    },
  },
  server: {
    port: 5173,
    proxy: { "/api": "http://localhost:8787", "/v1": "http://localhost:8787" },
  },
  test: { environment: "jsdom", include: ["src/**/*.test.{ts,tsx}", "test/**/*.test.{ts,tsx}"] },
});
