# PDF upload — parser handoff (`feat/pdf-parser`)

## Done
- `unpdf` 1.9.1 (pinned) added to `@sroka/parser`. It runs in the workers vitest pool (workerd) with the default serverless build; no special options needed.
- `workers/parser/src/pdf.ts`: `processPdfJob`, dispatched at the top of `processJob` when `job.pdf` is set (so `parseWanted` + retry/backoff in `index.ts` apply as for other jobs).
  Reads `document.pdf`, extracts page by page (first 300 pages, stops at ~2 MB, then `capUtf8` cuts at exactly 2 MiB on a code point boundary), writes `text.txt`
  (best effort, skipped when `stillWanted` turns false), result `ok` with `contentId`, `contentPrivate:true`, `siteName:"PDF"`, title/author/lang/excerpt/wordCount/readingMinutes.
- Error codes (all `status:"ok"`, null metadata): `pdf_no_text` (no words), `pdf_encrypted` (PasswordException), `pdf_extract_failed`. R2 read errors throw `TransientError` (retry).
  Missing `document.pdf` returns `failed` / `pdf_missing` (item deleted or upload never landed); this is the only failed result besides retries exhausted / DLQ.
- `src/pdf-text.ts`: `cleanPdfTitle` (strips "Microsoft Word|PowerPoint|Excel - " prefix and file extension; null for empty, paths/URLs, generic like Untitled/Document1/PowerPoint Presentation), `cleanPdfString`, `cleanPdfLang`, `normalizePdfText`, `wordCountOf`, `pdfExcerpt`, `capUtf8`.
- `index.ts`: on `markParsed` ok:false a pdf job deletes only `text.txt` (previously the whole dir, which would have removed the original). DLQ path unchanged: `failedResult` has no contentId and a failed `markParsed` only touches parse_status/error.
- `attempts.ts`: pdf jobs log `domain:"pdf"`, `source:"pdf"`, `method:"pdf"`, url NULL. `ParseMethod` gained `"pdf"`. No `content` row, no shared cache.
- Logging: nothing logs text or file names (only itemId, error name).

## Verification
- `npm test -w @sroka/parser`: 73 passed (new: `test/pdf-text.test.ts`, `test/pdf.test.ts`; fixture generated in `test/pdf-fixture.ts`, valid xref, optional fake /Encrypt, empty pages for a "scan").
  Covered: happy path with metadata + no fetch + no content row + attempts row, generic title, no-text, encrypted, garbage bytes, 300-page cap, superseded job, R2 read failure retry, missing object, ok:false keeps document.pdf, DLQ.
- `npm run typecheck -w @sroka/parser`: only error is `workers/api/src/do/rows.ts(70)` missing `kind/fileName/fileSize` on `ItemData` — that is the API branch's work (shared contract is already updated), not parser code.

## CPU / memory notes
- The whole PDF is loaded (`arrayBuffer`, up to 50 MiB) and pdf.js holds parsed structures: a 50 MiB PDF can approach the 128 MB isolate limit. An OOM kills the isolate -> queue retry -> eventually DLQ -> `failed`; the item stays readable. Not load-tested with real large files.
- Extraction is CPU-bound (~0.7 s for a 1-page fixture incl. pdf.js init in the test pool). 300 text-heavy pages may exceed the default 30 s CPU limit (default CPU limit 30 s on paid; the limit is configurable via `limits.cpu_ms` in wrangler.jsonc if it shows up in `parse` logs as `durationMs`). Jobs run sequentially in a batch.
- pdf.js drops text positioned outside the page box, so fixtures must keep lines short.

## Open items
- API branch: markParsed for pdf items must accept `contentId === items.content_id`, not delete the dir, and handle `failed pdf_missing`; `parse_attempts.method` comment in `workers/api/src/db/schema.ts` should list `pdf` (not touched here; ownership).
- Consider `limits.cpu_ms` and a size guard (e.g. skip extraction above ~40 MiB with `pdf_extract_failed`) after real-world measurement.
- Bundle: `wrangler deploy --dry-run` = 4249 KiB / 958 KiB gzip (under the 3 MiB gzip free limit; fine on paid).
