# @sroka/extension — WXT MV3 Chrome extension

Popup (sign-in email → 6-box code, saving → success → saved with tags/favourite/remove/open, tag editor, removed, queued/failed), context menus (save link/page; right-click the toolbar icon → "Open Sroka" opens `${appOrigin}/app/` in a new tab via `lib/open-app.ts`), per-tab badge, retry queue, options page.

## Commands
- `npm run dev -w @sroka/extension` · `npm run build -w @sroka/extension` → `.output/chrome-mv3` · `npm run zip -w @sroka/extension`
- Manifest `key` pins the unpacked id to `gmfnkkciofcaafddbcgphofiikmplema` (= API `EXT_ID`); `zip` sets `SROKA_STORE_BUILD=1` to omit it (Web Store rejects `key`).
- `npm run typecheck -w @sroka/extension` (runs `wxt prepare` first) · `npm test -w @sroka/extension`

## Key files
- Popup implements Claude Design "Sroka Popup"/"Sroka Extension" (dark only, 340px): `entrypoints/popup/App.tsx` + `assets/popup.css`. Options page uses `assets/tailwind.css` (light/dark). Brand mark + glyph in `components/Mark.tsx`.
- `wxt.config.ts` (manifest, permissions, dev host permission for localhost:8787), `entrypoints/background.ts`, `entrypoints/popup/*`, `entrypoints/options/*`, `assets/tailwind.css`.

## Decisions that apply
D8 (features, server URL option default `https://api.sroka.app`; when the user saves a custom URL the options page must call `chrome.permissions.request({ origins: [new URL(url).origin + "/*"] })` — allowed by `optional_host_permissions` — and refuse to save if denied; "Open library" opens `${appOrigin}/app/` from `GET /v1/config`), D4 (bearer token from `set-auth-token` header, `chrome.storage.local`), D1.
Capture: `saveTab` sends the rendered `html` when the "always capture" option is on (default **on**), and always when `detectPaywall` matches or `alwaysCapture(url)` (Reddit), both from `@sroka/shared`. `pageHtmlForCapture` runs in the page and strips scripts (except JSON-LD), styles, stylesheet/preload links, SVG and templates. `saveItem` gzips the body (`Content-Encoding: gzip`) when it carries `html`. Tests read request bodies with `requestJson` (`lib/test-chrome.ts`).
API: `POST /v1/items` (with `html` when capturing), `GET /v1/items?url=` for the badge, `GET /v1/tags/suggestions?url=`, `PATCH /v1/items/:id {tags}`. See `docs/api.md` and research/ext.md gotchas. Don't add deps.
