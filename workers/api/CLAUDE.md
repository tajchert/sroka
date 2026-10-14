# @sroka/api — Worker `sroka-api`

Hono app: Better Auth (`/api/auth/*`), `/v1/*` (contract: `docs/api.md`, schemas: `@sroka/shared`), per-user `LibraryDO`,
signed content route on the `CONTENT_ORIGIN` host, static web assets (`../../apps/web/dist`) with SPA fallback for `/app/*`.

## Commands
- `npm run dev -w @sroka/api` — `scripts/dev.mjs`: writes `wrangler.dev.jsonc` (gitignored; `wrangler.jsonc` minus `routes`) and runs
  `wrangler dev -c wrangler.dev.jsonc -c ../parser/wrangler.jsonc` on :8787 — ONE process for both workers, so the parser shares the
  local D1/R2/KV state (`workers/api/.wrangler/state`), calls the same `LibraryDO`, and consumes `sroka-parse` in-process. Extra args pass through (`-- --port 8788`).
  **Don't run plain `wrangler dev` on `wrangler.jsonc`**: with `routes` set, wrangler dev rewrites URLs to `http://sroka.app` and rewrites
  `Origin: http://localhost:8787` → `http://sroka.app` (Better Auth 403 `INVALID_ORIGIN`; content host 127.0.0.1 not recognised). See decisions D3.

## Local stack (first time)
1. `npm run dev:setup` (root) = `node scripts/dev-setup.mjs` (creates `workers/{api,parser}/.dev.vars` with random secrets if missing)
   + `npm run db:migrate:local -w @sroka/api` (D1 migrations into `workers/api/.wrangler/state`) + `npm run build -w @sroka/web` (assets).
2. `npm run dev -w @sroka/api > /tmp/sroka-dev.log 2>&1 &` — app http://localhost:8787 (`/`, `/app/`), content host http://127.0.0.1:8787.
   OTP codes are logged: `[sroka] OTP for <email>: <code>`.
3. Optional: `npm run dev -w @sroka/web` — vite :5173 proxying `/api` + `/v1` (needs `DEV_ORIGINS=http://localhost:5173`, in the example).
4. `DEV_LOG=/tmp/sroka-dev.log npm run e2e:local` — `scripts/e2e-local.sh`: curl walk-through of auth, saves + parse, signed content
   (CSP/CORS/tamper), tags, filters, PATCH, sync push/pull, vite proxy (if running), account deletion. Exits non-zero on failure.
   Needs internet (saves Wikipedia + a blog post; `SKIP_PUBLIC=1` to skip). Better Auth rate limits (OTP send 3/min, sign-in 3/10 s per IP) make it wait on reruns.
- Local Images binding = sharp (miniflare); if sharp is unavailable it returns 503 and the parser falls back to the original image bytes (`img/{sha}.{jpg|png|…}`, no thumbnail).
- Reset local state: stop dev, `rm -rf workers/api/.wrangler/state`, re-run `npm run db:migrate:local -w @sroka/api`.
- `npm test -w @sroka/api` — vitest + `@cloudflare/vitest-plugin` (workerd). Tests in `test/`. `fsModuleCache: false` is required (vitest 5 cache bug with the plugin). `vitest.config.ts` overrides vars/secrets with test values (`ENVIRONMENT=development`, local origins, test `BETTER_AUTH_SECRET`/`CONTENT_URL_SIGNING_KEY`) because wrangler.jsonc vars are production and `.dev.vars` is gitignored.
- `npm run typecheck -w @sroka/api`
- Auth schema: `npm run auth:schema -w @sroka/api` (needs `auth.cli.ts` stub, see docs/research/auth.md), then `npm run db:generate -w @sroka/api`, `npm run db:migrate:local -w @sroka/api`.
- Deploy dry-run: `npx wrangler deploy --dry-run --outdir /tmp/x` (from this dir; web must be built first for assets).

## Key files
- `wrangler.jsonc` — bindings DB (D1 sroka, real id; local dev uses local state), CONTENT (R2), CONFIG (KV sroka-config), LIBRARY (DO + migration v1), PARSE_QUEUE, EMAIL, IMAGES, ASSETS, vars; routes sroka.app / api.sroka.app / c.sroka.app.
- `src/env.ts` — hand-written `Env` (we use `@cloudflare/workers-types`, not `wrangler types`). Keep in sync with wrangler.jsonc.
- `src/index.ts` — Hono app (content-host branch, CORS, Better Auth, `/v1` routes, asset/SPA fallback), `export { LibraryDO }`.
- `src/library-do.ts` — DO RPC surface; logic in `src/do/` (`schema.ts` migrations via `_schema` table, `store.ts` applyOps/LWW/pull/list, `rest.ts`, `sign.ts`).
- `src/auth.ts` (createAuth per request), `src/email.ts`, `src/db/schema.ts` + `src/db/auth-schema.ts` (drizzle), `migrations/`, `src/routes/*.ts` (content, account, config, items, tags, sync, imports, exports), `src/assets.ts`.
- `scripts/dev.mjs` — local dev launcher (see Commands).

## Decisions that apply
D3 (hosts, run_worker_first, CORS), D4 (auth), D5 (LibraryDO, applyOps single path, LWW, D1 tables), D6 (producer, raw HTML key), D7 (content route + headers), D8 (assets/SPA fallback), D9.
Gotcha (research/auth.md): type `ctx` as `{ waitUntil(p: Promise<unknown>): void }` — Hono's executionCtx doesn't satisfy workers-types 5 `ExecutionContext`.
Deps already installed (hono, better-auth, drizzle-orm, zod, fflate, linkedom for import HTML parsing; dev: wrangler, drizzle-kit, `auth` = Better Auth CLI 1.7.8). Don't add deps.
