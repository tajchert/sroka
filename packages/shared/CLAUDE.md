# @sroka/shared — the contract

Zod 4 schemas + TS types shared by api, parser, web, extension. Consumed as TS source (`exports: ./src/index.ts`), no build.
**Changing anything here changes the contract — update `docs/api.md` in the same commit.**

## Commands
- `npm test -w @sroka/shared` (plain node vitest) · `npm run typecheck -w @sroka/shared`

## Key files (src/)
- `ids.ts` — `uuidv7()` (monotonic), `isUuid`, `uuidv7Time`
- `url.ts` — `normalizeUrl` (rules in file header / docs/api.md), `urlHash` (sha256 hex), `isHttpUrl`, `extractFirstUrl`, `displayDomain`
- `limits.ts` — `LIMITS` (push ≤500 ops, html ≤5 MB, skew 5 min, tombstones 180 d, content URL TTL 24 h…), `readingMinutes`, `PROGRESS_ANCHOR_SELECTOR`
- `model.ts` — `Item`, `Tag`, `Job`, `User`, enums (`ItemState`, `ItemSort`, `ParseStatus`, `ItemSource`, `ImportFormat`, `ExportFormat`), `TagName` (normalizes), `tagKey` (Unicode case-fold key = `tags.name_key`)
- `ops.ts` — sync `Op` discriminated union (design §8.2 + `item.setTitle`, `tag.delete`), `PushRequest/PushResponse`, `PullQuery/PullResponse`, `RejectReason`, `REST_DEVICE_ID`
- `api.ts` — every `/v1` request/response schema, `ApiError`, `ErrorCode`, `toApiError` (zod error → 400 body), list cursor helpers
- `parse.ts` — `ParseJobSchema` (queue message), `ParseResultSchema` (`LibraryDO.markParsed`; both carry `parseGen`), `PARSER_VERSION`, `PackageManifest`, `r2Keys`
- `content-sign.ts` — D7 signed content URLs: `signContentPath`, `verifyContentPath`, `buildContentUrls`, `contentScope`
- `lww.ts` / `hlc.ts` — per-field LWW (`applyLww`, `pairWins` for item_tags, `clampAt`, `ItemClock`), client `OpClock`

## Rules
- Decisions D2, D5, D7, D9 apply. Pure WebCrypto/zod only — must run in Workers, browsers, extension service worker and node.
- Relative imports use the `.ts` extension.
