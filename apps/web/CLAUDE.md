# @sroka/web — landing + React SPA

Vite multi-page: `index.html` = static landing at `/`; `app/index.html` = SPA at `/app/` (react-router 7 data mode, `basename: "/app"`), TanStack Query, Tailwind v4.
Built to `dist/`, served by `sroka-api` as static assets (same origin as `/v1` and `/api/auth`).

## Commands
- `npm run dev -w @sroka/web` (vite :5173, proxies `/api` and `/v1` to :8787) · `npm run build -w @sroka/web` · `npm test -w @sroka/web` (vitest + jsdom + @testing-library/react) · `npm run typecheck -w @sroka/web`

## Key files
- `vite.config.ts`, `index.html` + `src/landing.css` (landing), `app/index.html` + `src/main.tsx` (router), `src/tokens.css` (brand tokens), `src/lib/{api,reader,cache,hooks,store}`, `src/routes/*`, `src/components/*`.
- `lib/reader.ts` builds the sandboxed srcdoc (CSP, base, theme CSS, nonce script); settings are pushed via postMessage, not rebuilt.

## Decisions that apply
D8 (stack, same-origin `credentials: "same-origin"`, reader = sandboxed iframe srcdoc with `<base href={baseUrl}>` from `GET /v1/items/:id/content`), D7, D4 (cookie auth via Better Auth email OTP; `better-auth/react` client available), D1 scope.
Contract: `docs/api.md`; validate/parse with `@sroka/shared` schemas. Use the `frontend-design` skill; brand = magpie (black/white + iridescent blue-green). Only extra dep: `firebase` (D15; lazy, consent-gated; config `firebase.config.json`, see `lib/analytics.ts`, `lib/consent.ts`).

## Reader end card (`lib/reader.ts`, `routes/Reader.tsx`)
The finish card is drawn inside the sandboxed frame (the parent never touches frame DOM), over postMessage:
- Frame → parent: `sroka:fits` (article fits without scrolling, sent after load/resize/settings; progress is not reported or stored), `sroka:metrics` (progress ≥ 0.98 latches `reachedEnd`), `sroka:endAction` `{action: "archive" | "keep" | "next"}`.
- Parent → frame: `sroka:endCard` `{card}` with final strings (`endCardModel`) or `null` to clear. Frame code writes them with `textContent` only.
- The frame always appends an empty `#sroka-end` block (min-height 19rem, replaces the bottom padding) so showing/hiding the card never changes scroll height, hence never the progress maths or resume anchor. Keep that block reserved; don't append content after it.
- Card shows only for readable items (`ok`/`partial`, not PDF) once `reachedEnd` and the next-item lookup (`useNextItem`) has answered; "Keep" hides it for the visit.

## Re-save with extension (`lib/extension.ts`, `components/ResaveButton.tsx`)
On a paywalled item ("Preview only" banner in `routes/Reader.tsx`) the banner adds a button (puzzle icon, "Re-save with extension") only when the Sroka extension in THIS browser answers a ping; otherwise the banner is unchanged.
- Extension ids: `EXTENSION_IDS` in `lib/extension.ts` (dev/unpacked `gmfnkkciofcaafddbcgphofiikmplema`). Add the Chrome Web Store id there (one line) when the listing exists; the API `EXT_ID` must trust it too.
- Channel: the extension's manifest `externally_connectable` lists `https://sroka.app/*` (and `http://localhost/*` in non-store builds), so Chrome exposes `chrome.runtime.sendMessage(id, msg, cb)` on those origins only. No `chrome.runtime` / no answer / `lastError` / 1.5 s timeout → not installed.
- Messages: `{type:"sroka.ping"}` → `{ok:true, version}`; `{type:"sroka.resave", itemId, url}` (sent from the click) → `{ok:true, opened:true, auto}` or `{ok:false, error}`. The extension opens the original itself; on a refusal (extension signed out, another account) the web opens the original like "Open original". `auto:false` means the user clicks the Sroka button on the opened page (its badge shows ↻) to save the full page; when the user comes back to the reader tab the button refetches `["item", id]` (the app does not refetch on focus), so the pending re-parse runs the normal parse polling and the full text replaces the preview. Full contract: `apps/extension/CLAUDE.md`.
