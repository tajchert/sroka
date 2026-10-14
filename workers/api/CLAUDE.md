# @sroka/api — Worker `sroka-api`

Hono app: Better Auth (`/api/auth/*`), `/v1/*` (contract: `docs/api.md`, schemas: `@sroka/shared`), per-user `LibraryDO`,
signed content route on the `CONTENT_ORIGIN` host, static web assets (`../../apps/web/dist`) with SPA fallback for `/app/*`.

## Commands
- `npm run dev -w @sroka/api` — wrangler dev :8787 with the parser worker too (`-c ../parser/wrangler.jsonc`). Needs `.dev.vars` (copy `.dev.vars.example`).
- `npm test -w @sroka/api` — vitest + `@cloudflare/vitest-plugin` (workerd). Tests in `test/`. `fsModuleCache: false` is required (vitest 5 cache bug with the plugin).
- `npm run typecheck -w @sroka/api`
- Auth schema: `npm run auth:schema -w @sroka/api` (needs `auth.cli.ts` stub, see docs/research/auth.md), then `npm run db:generate -w @sroka/api`, `npm run db:migrate:local -w @sroka/api`.
- Deploy dry-run: `npx wrangler deploy --dry-run --outdir /tmp/x` (from this dir; web must be built first for assets).

## Key files
- `wrangler.jsonc` — bindings DB (D1 sroka, id `LOCAL` placeholder), CONTENT (R2), CONFIG (KV placeholder id), LIBRARY (DO + migration v1), PARSE_QUEUE, EMAIL, IMAGES, ASSETS, vars; routes sroka.app / api.sroka.app / c.sroka.app.
- `src/env.ts` — hand-written `Env` (we use `@cloudflare/workers-types`, not `wrangler types`). Keep in sync with wrangler.jsonc.
- `src/index.ts` — Hono app, `export { LibraryDO }`. `src/library-do.ts` — DO (placeholder).
- Planned: `src/auth.ts` (createAuth per request), `src/db/schema.ts` + `src/db/auth-schema.ts` (drizzle), `migrations/`, `src/routes/*.ts`, `src/content.ts`.

## Decisions that apply
D3 (hosts, run_worker_first, CORS), D4 (auth), D5 (LibraryDO, applyOps single path, LWW, D1 tables), D6 (producer, raw HTML key), D7 (content route + headers), D8 (assets/SPA fallback), D9.
Gotcha (research/auth.md): type `ctx` as `{ waitUntil(p: Promise<unknown>): void }` — Hono's executionCtx doesn't satisfy workers-types 5 `ExecutionContext`.
Deps already installed (hono, better-auth, drizzle-orm, zod, fflate, linkedom for import HTML parsing; dev: wrangler, drizzle-kit, @better-auth/cli). Don't add deps.
