# @sroka/parser — Worker `sroka-parser`

Queue consumer of `sroka-parse` (batch 5, max_retries 3, DLQ `sroka-parse-dlq`, which it also consumes to mark items failed).
Runs `@sroka/extractor`, writes R2 (`CONTENT`), D1 `content` cache rows (`DB`), transforms images (`IMAGES`), then calls `LIBRARY` DO RPC `markParsed(itemId, ParseResult)` (DO lives in `sroka-api`, `script_name`).

## Commands
- `npm test -w @sroka/parser` (vitest + @cloudflare/vitest-plugin, `test/`; `fsModuleCache: false` required). Tests run with `main: ./test/entry.ts`, which re-exports the parser handler **and** `LibraryDO` from `../../api/src/library-do.ts`; `vitest.config.ts` maps `LIBRARY` to that local class (the real binding points at `script_name: "sroka-api"`, which doesn't exist in workerd tests) and overrides vars to dev values. · `npm run typecheck -w @sroka/parser`
- Local: started together with the API by `npm run dev -w @sroka/api`.

## Key files
- `wrangler.jsonc` — consumers, LIBRARY (script_name sroka-api), DB (migrations in ../api/migrations), CONTENT, CONFIG, IMAGES, vars.
- `src/env.ts` — `ParserEnv`; `LIBRARY` is typed by a local minimal RPC interface (`markParsed`, `parseWanted`, `reemitContentRefs`).
- `src/gc.ts` — weekly `scheduled()` cron (wrangler `triggers.crons`) = `runWeeklyGc`: deletes `private/`, `raw/`, `uploads/` of user ids no longer in D1, expired `auth_throttle` rows; content-ref backfill; shared-content GC (below).
- `src/index.ts` — `queue()` handler: retry/backoff (30s*2^n, last attempt marks failed), DLQ branch. `src/process.ts` — `processJob` (cache lookup, raw/fetch, buildContent, R2 writes, D1 `content` insert). Cache needs `meta.json` in the content dir (written last).
- Tests stub `globalThis.fetch` and override `IMAGES`/`LIBRARY` in env; `vitest.config.ts` pre-bundles sanitize-html/postcss (CJS) for workerd.
  `test/d1.ts` applies the real `../api/migrations`; `test/content-gc.test.ts` runs refs + GC end to end against the real LibraryDO.

## Shared-content GC (api.md §9 "Content references / GC", decisions D6)
LibraryDOs report public content references to D1 `content_refs` (outbox, at-least-once). The cron deletes `content` rows +
`content/{id}/` with no refs and `last_used_at` older than 30 days (≤200 rows / ~20k R2 objects per run, `gc summary` log line).
It is a **no-op until `gc_state.gc_backfill_done = '1'`**, which only the backfill sets. Production rollout (in this order):
1. D1 migration 0002 first (the new parser and DO write the new columns/tables): `cd workers/api && npx wrangler d1 migrations apply sroka --remote`
2. Deploy sroka-api (DO schema v3 + outbox; from now on every reference change is reported): `npm run build -w @sroka/web && cd workers/api && npx wrangler deploy`
3. Deploy sroka-parser: `cd workers/parser && npx wrangler deploy`
4. Start the backfill (only after step 2 is live — libraries re-emit their current refs, later changes go through the outbox):
   `cd workers/api && npx wrangler d1 execute sroka --remote --command "INSERT INTO gc_state (k, v) VALUES ('gc_backfill', 'start') ON CONFLICT(k) DO UPDATE SET v = 'start'"`
5. The next cron run (Sun 04:23 UTC) calls `reemitContentRefs()` on every user's LibraryDO (1000 users/run, resumable cursor
   `gc_backfill_cursor`; stops at a user whose flush fails and retries it next run), sets `gc_backfill_done`, and the GC starts
   in the same run. Check: `npx wrangler d1 execute sroka --remote --command "SELECT * FROM gc_state; SELECT COUNT(*) FROM content_refs"` and the `gc summary` log.
Emergency stop: `DELETE FROM gc_state WHERE k = 'gc_backfill_done'` (GC becomes a no-op again; rerun the backfill by also deleting `gc_backfill_cursor`).

## Decisions that apply
D6 (pipeline, message `ParseJob`, images WebP 1600/thumb 400 + fallback, 7-day public cache by url_hash + PARSER_VERSION, private never shared), D5 (R2 layout), D7 (scope p vs u.{userId}).
Messages are `ParseJob` from `@sroka/shared`; results are `ParseResult`. Don't add deps.
