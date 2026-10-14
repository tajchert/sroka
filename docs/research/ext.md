# WXT extension and React SPA research brief (2026-10-14)

Both throwaway projects built. WXT: `wxt build` and `wxt zip` passed. The only `tsc --noEmit` error was an `r` possibly undefined from WXT's strict tsconfig, fixed with `r?.result`. SPA: `vite build` and `tsc` passed. Projects are at `/private/tmp/claude-501/sroka-research/wxt` and `/private/tmp/claude-501/sroka-research/spa`.

## Versions (from `npm view`, Node v26)
| Package | Version |
|---|---|
| wxt | 0.21.4 (engines node >=22; peer vite ^6.3.4 \|\| ^7 \|\| ^8; it built with vite 8.3.4) |
| @wxt-dev/module-react | 1.2.2 |
| react, react-dom | 19.3.1 |
| vite | 8.3.4 |
| @vitejs/plugin-react | 6.1.2 |
| react-router | 8.4.0 (use `react-router`; `react-router-dom` is no longer needed) |
| @tanstack/react-query | 5.104.2 |
| tailwindcss, @tailwindcss/vite | 4.3.3 |
| typescript | 7.0.2 is "latest", but I tested with `typescript@5`. WXT's peer range is >=5.4. TS 7 is untested; pin 5.x. |
| @types/chrome | 0.3.5, not needed with WXT |

WXT auto-imports `browser`, `defineBackground`, `defineContentScript` and the `Browser` namespace type. The `browser.*` API is the promise-based `wxt/browser` wrapper over `chrome`.

## WXT layout
Run `npm i -D wxt @wxt-dev/module-react typescript` and `npm i react react-dom @types/react @types/react-dom`. Add the scripts `"dev": "wxt"`, `"build": "wxt build"`, `"zip": "wxt zip"`, `"postinstall": "wxt prepare"` and `"compile": "tsc --noEmit"`.

```
apps/extension/
  wxt.config.ts
  tsconfig.json      {"extends":"./.wxt/tsconfig.json","compilerOptions":{"jsx":"react-jsx"}}
  entrypoints/
    background.ts
    content.ts       (only if needed; the scripting API makes it optional)
    popup/index.html, main.tsx, App.tsx
    options/index.html, main.tsx
```

- Each HTML entrypoint needs `<div id="root">` and `<script type="module" src="./main.tsx">`.
- The options page uses `<meta name="manifest.open_in_tab" content="true"/>`. This is verified in the output as `options_ui.open_in_tab: true`.

## wxt.config.ts (verified output)
```ts
import { defineConfig } from 'wxt';
export default defineConfig({
  modules: ['@wxt-dev/module-react'],
  manifest: {
    name: 'Sroka',
    description: 'Save pages to read later',
    permissions: ['activeTab', 'contextMenus', 'storage', 'scripting'],
    host_permissions: ['https://api.sroka.app/*'],
    commands: {
      'save-page': {
        suggested_key: { default: 'Alt+Shift+S', mac: 'Alt+Shift+S' },
        description: 'Save current page to Sroka',
      },
    },
  },
});
```
- WXT generates the `action` (popup), `background.service_worker` and `options_ui` entries automatically.
- For the version in the manifest, set `"version"` in package.json. It defaults to 1.0.0 here.
- Dev builds against `localhost:8787` need an additional `http://localhost:8787/*` host permission. Add it conditionally with `import.meta.env.MODE === 'development'`. This is unverified.

## background.ts (compiles and builds)
```ts
export default defineBackground(() => {
  const API = 'https://api.sroka.app';
  const token = async () => (await browser.storage.local.get('token')).token as string | undefined;

  async function capture(tabId: number) {
    const [r] = await browser.scripting.executeScript({
      target: { tabId }, func: () => document.documentElement.outerHTML });
    return r?.result as string;            // strict TS: r may be undefined
  }
  async function save(body: object) {
    const res = await fetch(`${API}/api/items`, { method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${await token()}` },
      body: JSON.stringify(body) });
    return res.ok;
  }
  async function savePage(tab: Browser.tabs.Tab) {
    if (!tab.id) return;
    const ok = await save({ url: tab.url, html: await capture(tab.id) });
    await browser.action.setBadgeText({ text: ok ? '✓' : '!', tabId: tab.id });
    await browser.action.setBadgeBackgroundColor({ color: ok ? '#16a34a' : '#dc2626' });
    setTimeout(() => browser.action.setBadgeText({ text: '', tabId: tab.id }), 2500);
  }
  browser.runtime.onInstalled.addListener(() => {
    browser.contextMenus.create({ id: 'save-page', title: 'Save page to Sroka', contexts: ['page'] });
    browser.contextMenus.create({ id: 'save-link', title: 'Save link to Sroka', contexts: ['link'] });
  });
  browser.contextMenus.onClicked.addListener(async (info, tab) => {
    if (info.menuItemId === 'save-link') await save({ url: info.linkUrl });
    else if (tab) await savePage(tab);
  });
  browser.commands.onCommand.addListener(async (cmd) => {
    if (cmd !== 'save-page') return;
    const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
    if (tab) await savePage(tab);
  });
});
```

## Gotchas (extension)
- **Context menus:** create them inside `onInstalled`, not on every service-worker start. Duplicate ids throw. With `contextMenus` permission and a service worker, no persistent page is needed.
- **`activeTab`:** it is granted on a user gesture, meaning popup open, command or context-menu click. It lets `executeScript` run on the current tab without broad host permissions. A background save through the command or context menu works with `activeTab` alone (documented behavior, not run in a browser).
- **Page-HTML size:** `outerHTML` can be several MB. Send it in the request body (the Worker limit is 100MB on paid plans, but keep it under about 5MB). Consider also sending `document.title` and `location.href`, and do not send HTML for restricted `chrome://` pages. `executeScript` throws on chrome://, the Web Store and PDFs, so wrap it in try/catch and fall back to a URL-only save so the server fetches the page.
- **`executeScript` `func`:** it must be self-contained because it is serialized, so it cannot close over variables. The result is JSON-cloned.
- **CORS from the background worker:** with `host_permissions: ['https://api.sroka.app/*']`, extension-origin fetches bypass CORS. The server needs no `Access-Control-Allow-Origin` for extension requests, though the preflight is skipped. Without the host permission, the request origin is `chrome-extension://<id>` and the API must allow it. Cookies are not sent cross-site, which is fine here because we use `Authorization: Bearer`.
- **Auth flow:** run the OTP login in the popup. Better Auth's bearer plugin returns the session token in the `set-auth-token` response header on sign-in. Read that header and store it in `browser.storage.local`. The service worker is ephemeral, so never keep the token in a global variable.
- **Badge:** `browser.action.setBadgeText` and `setBadgeBackgroundColor` need no permission. Pass `tabId` for a per-tab badge.
- **Keyboard shortcut:** the default `Alt+Shift+S` is suggested only. Users can rebind it at `chrome://extensions/shortcuts`. Chrome allows at most 4 suggested commands. Using `_execute_action` as the command key instead opens the popup.
- **Web Store:** `wxt zip` produced `.output/wxt-1.0.0-chrome.zip` (72 kB). It also writes a sources zip for Firefox only. Store review needs a justification for each permission (`scripting`, host permission) and an icon set. Put icons at `public/icon/{16,32,48,96,128}.png`; WXT auto-discovers them. I have not tested this.
- **Strict typing:** `.wxt/tsconfig.json` is strict, so `tsc` flags possibly undefined array elements. Run `wxt prepare` before `tsc`.
- **Content script:** unneeded for saving. The scripting API plus `activeTab` is enough, and a content script with `https://*/*` matches triggers a broad-host warning. Remove the content entrypoint unless something needs it. In my test it added the `https://*/*` content_scripts entry to the manifest.

## React SPA (served as Worker static assets)
```
npm i react react-dom react-router @tanstack/react-query
npm i -D vite @vitejs/plugin-react tailwindcss @tailwindcss/vite typescript@5 @types/react @types/react-dom
```
vite.config.ts (verified):
```ts
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: { proxy: { '/api': 'http://localhost:8787' } },
});
```
- `src/index.css` is the single line `@import "tailwindcss";`. There is no tailwind.config and no postcss config.
- Import `./index.css` in `main.tsx`.
- Tailwind v4 compiled its utilities in the build (CSS 4.7 kB).

Data-mode router with React Query (verified; build and tsc pass):
```tsx
import { createBrowserRouter, RouterProvider } from 'react-router';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
const router = createBrowserRouter([{ path: '/', element: <Home /> }]);
createRoot(el).render(
  <QueryClientProvider client={new QueryClient()}><RouterProvider router={router} /></QueryClientProvider>);
```
tsconfig for the SPA: `jsx: react-jsx`, `moduleResolution: bundler`, `strict: true`, `noEmit: true`, `types: ["vite/client"]`.

### Worker static assets (config only, not tested here)
```jsonc
"assets": { "directory": "./apps/web/dist", "not_found_handling": "single-page-application",
            "binding": "ASSETS", "run_worker_first": ["/api/*"] }
```
With `run_worker_first: ["/api/*"]`, only `/api/*` hits the Worker and everything else is served from assets. `run_worker_first` accepts an array of route patterns on recent wrangler. This is unverified, so check it against the Cloudflare docs.

## Notes for the plan
- The sroka.app domain should serve the SPA, with the API on either `api.sroka.app` or `sroka.app/api`. The extension's host_permissions must match whichever is chosen. If the API is served same-origin at `/api`, change the host permission to `https://sroka.app/*`.
- Version surprises: react-router is now v8 (single `react-router` package), Vite is 8 and TypeScript's latest is 7. I tested with Vite 8, React Router 8 and TS 5. TS 7 and `@types/chrome` were not exercised.
- Not verified: loading the built extension in a real Chrome, the actual command, context-menu and badge behavior, and OTP login through the popup.
