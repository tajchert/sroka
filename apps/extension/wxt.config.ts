import { existsSync, readFileSync } from "node:fs";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "wxt";

// Public key pinning the unpacked extension id to gmfnkkciofcaafddbcgphofiikmplema
// (set as the API's EXT_ID). The Chrome Web Store rejects `key`, so `npm run zip` omits it.
const EXT_PUBLIC_KEY =
  "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAuSytf9/5f+M1Cyj9JzwjIzZrKMCZKoGz9dngH9sOOFSGRM/LqkPZsqvJChEeKA1rbgZUT4WQTm9oK9LV9g8PG37EQlET4ZN6azibEqcGc7nKpoEysABFnxC87wtEatMAstRpqNzVspL8WK5NWfbXd1LaUHEP2VKopNBIFmc/Nhy4TJGBOU8kyzOrhq9pQrgON6Sw1VasVTzTwprP+gEdgfgA1o7oiZ3IxGoGVte3Nq7YBrXnDJErvN5KCcUrSCAa3Oi5u1UYdOlJXmRhCpDXaaHno6oZeNiastS95A+XxCupaDDZT7lGu1EhvtOvD57aXiqlEgqyBo3iSUPCkSFCGwIDAQAB";

// GA4 Measurement Protocol config (D15). Absent or invalid → null → analytics compiled as a no-op.
function readAnalyticsConfig(): { measurementId: string; apiSecret: string } | null {
  const file = new URL("./analytics.config.json", import.meta.url);
  if (!existsSync(file)) return null;
  try {
    const c = JSON.parse(readFileSync(file, "utf8")) as { measurementId?: unknown; apiSecret?: unknown };
    return typeof c.measurementId === "string" && c.measurementId && typeof c.apiSecret === "string" && c.apiSecret
      ? { measurementId: c.measurementId, apiSecret: c.apiSecret }
      : null;
  } catch {
    return null;
  }
}

export default defineConfig({
  modules: ["@wxt-dev/module-react"],
  vite: () => ({ plugins: [tailwindcss()], define: { __SROKA_GA__: JSON.stringify(readAnalyticsConfig()) } }),
  manifest: ({ mode }) => ({
    name: "Sroka — Save for later",
    description: "Save pages to read later in Sroka",
    ...(process.env.SROKA_STORE_BUILD ? {} : { key: EXT_PUBLIC_KEY }),
    permissions: ["activeTab", "contextMenus", "storage", "scripting", "alarms", "tabs"],
    host_permissions: [
      "https://api.sroka.app/*",
      ...(mode === "development" ? ["http://localhost:8787/*"] : []),
    ],
    // Custom server URL (options page): requested at runtime via chrome.permissions.request.
    optional_host_permissions: ["https://*/*", "http://localhost/*"],
  }),
});
