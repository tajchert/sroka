# @sroka/parser — Worker `sroka-parser`

Queue consumer of `sroka-parse` (batch 5, max_retries 3, DLQ `sroka-parse-dlq`, which it also consumes to mark items failed).
Runs `@sroka/extractor`, writes R2 (`CONTENT`), D1 `content` cache rows (`DB`), transforms images (`IMAGES`), then calls `LIBRARY` DO RPC `markParsed(itemId, ParseResult)` (DO lives in `sroka-api`, `script_name`).

## Commands
- `npm test -w @sroka/parser` (vitest + @cloudflare/vitest-plugin, `test/`; `fsModuleCache: false` required). Tests run with `main: ./test/entry.ts`, which re-exports the parser handler **and** `LibraryDO` from `../../api/src/library-do.ts`; `vitest.config.ts` maps `LIBRARY` to that local class (the real binding points at `script_name: "sroka-api"`, which doesn't exist in workerd tests) and overrides vars to dev values. · `npm run typecheck -w @sroka/parser`
- Local: started together with the API by `npm run dev -w @sroka/api`.

## Key files
- `wrangler.jsonc` — consumers, LIBRARY (script_name sroka-api), DB (migrations in ../api/migrations), CONTENT, CONFIG, IMAGES, vars.
- `src/env.ts` — `ParserEnv`. For a typed DO stub use `DurableObjectNamespace<import("../../api/src/library-do.ts").LibraryDO>` (type-only import).
- `src/index.ts` — `queue()` handler (placeholder).

## Decisions that apply
D6 (pipeline, message `ParseJob`, images WebP 1600/thumb 400 + fallback, 7-day public cache by url_hash + PARSER_VERSION, private never shared), D5 (R2 layout), D7 (scope p vs u.{userId}).
Messages are `ParseJob` from `@sroka/shared`; results are `ParseResult`. Don't add deps.
