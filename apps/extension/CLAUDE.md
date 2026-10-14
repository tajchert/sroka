# @sroka/extension — WXT MV3 Chrome extension

Popup (sign-in email→code, "Saved ✓", tag input with suggestions, open library), context menus, `Alt+Shift+S`, per-tab badge, retry queue, options page.

## Commands
- `npm run dev -w @sroka/extension` · `npm run build -w @sroka/extension` → `.output/chrome-mv3` · `npm run zip -w @sroka/extension`
- `npm run typecheck -w @sroka/extension` (runs `wxt prepare` first) · `npm test -w @sroka/extension`

## Key files
- `wxt.config.ts` (manifest, permissions, dev host permission for localhost:8787), `entrypoints/background.ts`, `entrypoints/popup/*`, `entrypoints/options/*`, `assets/tailwind.css`.

## Decisions that apply
D8 (features, server URL option default `https://api.sroka.app`; when the user saves a custom URL the options page must call `chrome.permissions.request({ origins: [new URL(url).origin + "/*"] })` — allowed by `optional_host_permissions` — and refuse to save if denied; "Open library" opens `${appOrigin}/app/` from `GET /v1/config`), D4 (bearer token from `set-auth-token` header, `chrome.storage.local`), D1.
API: `POST /v1/items` (with `html` when capturing), `GET /v1/items?url=` for the badge, `GET /v1/tags/suggestions?url=`, `PATCH /v1/items/:id {tags}`. See `docs/api.md` and research/ext.md gotchas. Don't add deps.
