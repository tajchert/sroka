# Handoff: PDF upload, API worker (`feat/pdf-api`)

## Done
- DO schema v4 (`items.kind/file_name/file_size`, partial index `items_pdf`); `rows.ts` maps them to `kind`/`fileName`/`fileSize`, so get/list/pull/export-JSON carry them (`SELECT *` everywhere).
- `POST /v1/items/pdf` (`routes/items.ts`): 411/413/415/400 checks, streamed to R2 + SHA-256 (`tee`, `DigestStream`, `FixedLengthStream`; a `TransformStream` guard counts bytes, enforces 50 MiB and the `%PDF-` marker), then DO RPC `addPdf` (duplicate readd / `storage_full` / insert + ParseJob with `pdf`). The R2 object is deleted on every non-created path.
- `item.refresh`, `requeueStalePending` (sweep) and new jobs carry `pdf:{contentId}` (`newParseJob`); `markParsed` for pdf items (`markParsedPdf`) accepts only same content id + private, never deletes the dir.
- `/content` returns `documentUrl`; content route serves `.pdf` as `application/pdf`, inline disposition, CSP `default-src 'none'; object-src 'none'; frame-ancestors 'none'` (no sandbox).
- `GET /pdf/:sha256` (`routes/pdf-link.ts`, mounted in `index.ts`; `run_worker_first` is already true so no wrangler change).
- `docs/api.md`: §4.1, §5.7, new §5.8 (+ `/pdf/:sha256`), §9 (PDF jobs), §10 (headers), §14, §15.

## Verified
- `npm test -w @sroka/api`: 19 files, 137 tests pass (new: `test/routes-library/pdf.test.ts`, `test/platform/pdf-link.test.ts`, pdf case in `content-cors.test.ts`; schema version assertion bumped to 4).
- `npm run typecheck -w @sroka/api` and `-w @sroka/shared` green.
- Not done: local-stack curl check, Chrome check.

## Open items
- **Needs Chrome check**: the `.pdf` CSP and whether Chrome's viewer renders the signed URL when opened directly (and via `/pdf/:sha` redirect). If not, loosen the CSP in `src/routes/content.ts` (`PDF_CSP`) and `docs/api.md` §10.
- Deviation: a `failed` ParseResult for a pdf item is accepted (status/error only, content untouched) instead of `ok:false`, otherwise a DLQ failure would leave the item `pending` and re-swept forever. ok/partial with a different content id or non-private are refused as specified.
- Upload tolerates `application/octet-stream` (mobile clients); magic bytes are authoritative.
- `/v1/me` `pdfBytes` not added (optional). JSON export gained `kind/fileName/fileSize` per item; re-importing an exported PDF item's `/pdf/<sha>` URL is now rejected `invalid_url` (counted as skipped) unless that pdf item exists.
- No contract bug found in `packages/shared`; unchanged.

## Review fixes
1. Commit outcome: the route deletes the uploaded object only on known pre-commit outcomes (DO rejection / `storage_full` / duplicate with intact original, stream failure, `LibraryDestroyedError`); an unknown `addPdf` outcome keeps it (reservation sweep reclaims it).
2. Duplicate with a lost `document.pdf`: route `HEAD`s the existing original; if missing it calls DO `repointPdf` (new contentId, seq bump, parse_gen + pdf job, old dir cleanup) and keeps the new copy.
3. Parser: pdf jobs never delete anything on `markParsed` `ok:false` (`workers/parser/src/index.ts`).
4. `opAdd` rejects `${APP_ORIGIN}/pdf/{64hex}` with `invalid_url` unless a live item holds that url hash (api.md §8.2 3a). `LibraryStore` got an `appOrigin` getter.
5. Reservations: DO schema v5 `pdf_uploads`; `reservePdfUpload` before `put`; alarm `sweepPdfUploads` (1 h, unreferenced only). Route cleanups run through `waitUntil`.
6. Parser: originals over 20 MiB are not read (`obj.size`): `ok` + `pdf_too_large`, null metadata (spec doc updated).
8. `cleanFileName` exported and hardened (`/ \ :` to `_`, `\p{Cf}` stripped, surrogate-safe truncation, empty to `document.pdf`; a missing/blank `name` is still `400 name_required`).
9. "client disconnected" uncaught errors: the guard no longer errors mid-body for non-PDF/over-long bodies (it keeps draining; the route reads `guard.abort`), and the `pipeTo` promise is kept and awaited. Tests print no uncaught errors. Note: a non-PDF body is now written to R2 transiently (<= declared length) before being deleted.
