import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "wxt";

export default defineConfig({
  modules: ["@wxt-dev/module-react"],
  vite: () => ({ plugins: [tailwindcss()] }),
  manifest: ({ mode }) => ({
    name: "Sroka — Save for later",
    description: "Save pages to read later in Sroka",
    permissions: ["activeTab", "contextMenus", "storage", "scripting"],
    host_permissions: [
      "https://api.sroka.app/*",
      ...(mode === "development" ? ["http://localhost:8787/*"] : []),
    ],
    // Custom server URL (options page): requested at runtime via chrome.permissions.request.
    optional_host_permissions: ["https://*/*", "http://localhost/*"],
    commands: {
      "save-page": {
        suggested_key: { default: "Alt+Shift+S", mac: "Alt+Shift+S" },
        description: "Save current page to Sroka",
      },
    },
  }),
});
