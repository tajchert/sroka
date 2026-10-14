# Sroka — read-later app (Pocket successor) on Cloudflare

Monorepo (npm workspaces). Product/design: `docs/sroka-system-design.md` (long — read only the section you need).
**Binding rulings: `docs/decisions.md`** (overrides the design doc). HTTP/sync contract: `docs/api.md`. Verified API snippets: `docs/research/*.md`.
Progress ledger: `docs/ledger.md`. Logging/metrics/alerts: `docs/observability.md` (use `log` from `@sroka/shared`, never bare `console.*`; never log secrets, emails, article content).

## Layout
- `packages/shared` — zod schemas, sync op types, URL normalizer, UUIDv7, content-URL signing (TS source, no build)
- `packages/extractor` — fetch/Readability/sanitize/images/package (pure, node+workers)
- `workers/api` — Worker `sroka-api`: Hono, Better Auth, `LibraryDO`, `/v1`, content route, static web assets
- `workers/parser` — Worker `sroka-parser`: queue consumer for `sroka-parse`
- `apps/web` — React SPA (`/app`) + landing (`/`)
- `apps/extension` — WXT MV3 Chrome extension

## Commands
- Install: `npm install` (root)
- Typecheck all: `npm run typecheck` · Test all: `npm test`
- One workspace: `npm test -w @sroka/shared`, `npm run typecheck -w @sroka/api`, etc.
- Local stack: `npm run dev:setup` once (.dev.vars, local D1 migrations, web build), then `npm run dev -w @sroka/api` (wrangler dev :8787, api + parser in one process) + optionally `npm run dev -w @sroka/web` (vite :5173, proxies /api,/v1). Details: `workers/api/CLAUDE.md` "Local stack".
- Local e2e: `DEV_LOG=<wrangler dev log> npm run e2e:local` (`scripts/e2e-local.sh`, curl + jq + node; non-zero exit on failure).
- Extension: `npm run build -w @sroka/extension` → `apps/extension/.output/chrome-mv3`
- Each workspace has its own CLAUDE.md with specifics.

## Conventions
- TypeScript strict, ESM. Zod schemas live in `@sroka/shared` and are reused by api/web/extension.
- Wire JSON camelCase, SQL snake_case. Errors `{error, message?}`.
- Keep test/build output short (`| tail -30`). Conventional commits.
