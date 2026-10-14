import { resolve } from "node:path";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import type { Plugin } from "vite";
import { defineConfig } from "vitest/config";

// Dev server: Vite's multi-page fallback serves the root index.html (landing) for unknown paths,
// so rewrite SPA deep links (/app, /app/items/x — not files like /app/main.tsx) to /app/index.html.
const spaAppFallback: Plugin = {
  name: "spa-app-fallback",
  configureServer(server) {
    server.middlewares.use((req, _res, next) => {
      if (req.url && /^\/app(\/(?!.*\.\w+$).*)?$/.test(req.url.split("?")[0]!)) req.url = "/app/index.html";
      next();
    });
  },
};

// Multi-page build (decisions D8): index.html = landing at "/", app/index.html = SPA at "/app/".
export default defineConfig({
  plugins: [spaAppFallback, react(), tailwindcss()],
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
