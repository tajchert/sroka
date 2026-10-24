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
- `src/index.ts` — `queue()` handler: retry/backoff (30s*2^n, last attempt marks failed), DLQ branch. `src/process.ts` — `processJob` (site rule, cache lookup, raw/fetch, extract, Browser Run fallback, buildContent, R2 writes, D1 `content` insert; fills `JobStats`). Cache needs `meta.json` in the content dir (written last).
- `src/site-rules.ts` (KV rules + 60 s isolate cache), `src/render.ts` (budgets + `BROWSER.quickAction("content")`), `src/attempts.ts` (`reportParse`: `parse` log + AE point + D1 `parse_attempts` row).
- Tests stub `globalThis.fetch` and override `IMAGES`/`LIBRARY` (and `BROWSER`/`METRICS` mocks in `test/render-rules.test.ts`; KV rules use the real miniflare `CONFIG`) in env; `vitest.config.ts` sets `BROWSER_RENDER_ENABLED=false` by default; `vitest.config.ts` pre-bundles sanitize-html/postcss (CJS) for workerd.
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

## Browser Run + site rules (decisions D10, api.md §9)
- Fallback render when the plain fetch hits a bot wall (403/429/503 or a challenge page), extracts nothing, or yields < 500 chars
  (rule `minTextChars`), or the rule says `render: "always"`. Never for captures; a short capture instead gets one plain fetch and keeps the longer text (still private). Budgets per user/day 30 and global/day 500 (vars,
  D1 `render_budget`). Off locally (`.dev.vars` `BROWSER_RENDER_ENABLED=false`; Browser Run doesn't run in `wrangler dev`).
- Paywalls (`detectPaywall`, `@sroka/shared` `src/paywall.ts`): a fetched/rendered page with paywall markup → `partial` / `paywalled`, no render for a short teaser; captures are never checked.
- **Site rules** live in KV `CONFIG` under `site-rules:v1:{host}` (host without `www.`; a rule for `example.com` also covers
  `blog.example.com` unless that has its own). Fields (`SiteRuleSchema`, unknown keys rejected): `render` auto|always|never,
  `contentSelector`, `removeSelectors[]`, `stripParams[]`, `userAgent` default|browser, `minTextChars`, `waitForSelector`,
  `disabled`, `note`, `updatedAt`. Invalid rules are ignored (`site_rule_invalid` warn). Changes apply within 60 s (isolate cache);
  already-cached shared content stays until refreshed (7-day cache). Add/edit a rule (run from `workers/parser`):
  `npx wrangler kv key put --remote --binding CONFIG "site-rules:v1:example.com" '{"render":"always","removeSelectors":[".paywall-teaser"],"note":"JS-rendered","updatedAt":1760486400000}'`
  Inspect / delete: `npx wrangler kv key get --remote --binding CONFIG "site-rules:v1:example.com"`, `npx wrangler kv key list --remote --binding CONFIG --prefix site-rules:v1:`, `npx wrangler kv key delete --remote --binding CONFIG "site-rules:v1:example.com"`.
  To find candidates: D1 `parse_attempts` queries in docs/observability.md.
- Production rollout: (1) `cd workers/api && npx wrangler d1 migrations apply sroka --remote` (0003: `parse_attempts`, `render_budget`)
  **before** (2) `cd workers/parser && npx wrangler deploy`. Browser Run needs the Workers Paid plan for real volume (free: 10 min/day);
  set `BROWSER_RENDER_ENABLED` to `"false"` in wrangler.jsonc and redeploy to switch it off.

## Decisions that apply
D10 (Browser Run fallback, site rules, parse analytics), D6 (pipeline, message `ParseJob`, images WebP 1600/thumb 400 + fallback, 7-day public cache by url_hash + PARSER_VERSION, private never shared), D5 (R2 layout), D7 (scope p vs u.{userId}).
Messages are `ParseJob` from `@sroka/shared`; results are `ParseResult`. Don't add deps.
