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
Contract: `docs/api.md`; validate/parse with `@sroka/shared` schemas. Use the `frontend-design` skill; brand = magpie (black/white + iridescent blue-green). Don't add deps.
