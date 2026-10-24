# PDF upload — Android data layer (handoff to the UI agent)

Branch `feat/pdf-android`. Spec: `docs/superpowers/specs/2026-10-24-pdf-upload-design.md`. Gate green:
`./gradlew testDebugUnitTest lintDebug assembleDebug` (apps/android, JDK 21). No UI/feature module was touched.

## Model (`core:model`)
- `ItemKind { ARTICLE, PDF }` (`ItemKind.fromWire`, unknown -> ARTICLE). `Item` has `kind`, `fileName: String?`, `fileSize: Long?` (defaults keep old call sites compiling).
  `ItemSummary` (list row) has `kind` and `fileSize` (show "PDF · 2.3 MB"; `siteName` is not in the summary, use `kind`).
- `PdfUpload(id, fileName, sizeBytes, state)` + `isActive`; `PdfUploadState = Queued | Uploading(progress 0..1) | Failed(error) | Done(itemId?, duplicate)`;
  `PdfUploadError = TOO_LARGE | NOT_PDF | STORAGE_FULL | NETWORK | UNKNOWN | AUTH` (AUTH is an addition to the spec list); `MAX_PDF_BYTES` (50 MiB).
- Test builders (`core:testing`): `testItem(kind=, fileName=, fileSize=)`, `testPdfItem()`.

## Uploads (`core:domain` `PdfUploader`, `app.sroka.core.domain.PdfUploader`; Hilt-bound in `core:data` DataModule)
```kotlin
val uploads: Flow<List<PdfUpload>>          // oldest first; survives process death (derived from WorkManager)
suspend fun enqueue(uris: List<Uri>): List<PdfUpload>   // SAF / share / drop content URIs; returns new entries in order
suspend fun cancel(id: String)
fun clearFinished()                          // forget Done/Failed entries (call after showing the snackbar)
```
- UI recipe: "Uploading N PDFs" row = `uploads.filter { it.isActive }` (Queued/Uploading); snackbar on transitions to `Done` (`duplicate=true` -> "Already in Sroka") or `Failed(error)` -> typed string. Call `clearFinished()` once shown.
- `enqueue` copies each file into `filesDir/pdf-uploads/{id}.pdf` (streamed, 50 MiB cap, `%PDF-` within the first KiB) and returns `Failed(...)` entries immediately for: over 50 MiB (TOO_LARGE), not a PDF/empty (NOT_PDF), device full (STORAGE_FULL), unreadable (UNKNOWN). No temp copy remains for those.
- Worker `PdfUploadWorker` (unique work `sroka-pdf-upload-{id}`, CONNECTED, exponential backoff 30 s): `POST /v1/items/pdf?name=&source=share` streaming the file with a known Content-Length. 413 TOO_LARGE, 415 NOT_PDF, 409 `storage_full` STORAGE_FULL, other 4xx UNKNOWN = permanent (temp file deleted, work FAILED). 401 (AUTH, marks session expired), 408/429/5xx (UNKNOWN), I/O (NETWORK) = transient: stay `Queued`, file kept, retried; after 15 attempts they become permanent Failed. Success: temp file deleted, `WorkScheduler.enqueueSync()` (pull brings the item), `Done(itemId, duplicate)`.
- Sign-out wipe cancels the work (tag `sroka`) and deletes `pdf-uploads/`. "Remove downloads" does not touch pending uploads.
- Fake: `core:testing` `FakePdfUploader` (`state`, `enqueued`, `nextError`, `set/progress/complete/fail`).

## Reading a PDF item (`core:domain` `ContentStore`)
```kotlin
suspend fun pdfFile(itemId: String): File?                 // local articles/{id}/document.pdf if DOWNLOADED, never networks
suspend fun ensurePdfFile(itemId: String): PdfFileResult   // Ready(file) | NotReady | Failed(RemoteFailure); downloads if needed
```
- `observeOffline(itemId)`, `downloadNow(itemId)`, auto-download per policy, eviction, "Remove downloads", storage usage all work for PDFs (same `content_files` row; the file is `filesDir/articles/{itemId}/document.pdf`).
- Download: `documentUrl` from `/v1/items/:id/content`; on 401/403/404/410 of the signed URL the URLs are re-fetched once; result validated (`%PDF-`, <= 50 MiB) before the atomic move.
- `FakeContentStore.pdfFiles` (MutableStateFlow<Map<id, File>>) feeds `pdfFile`/`ensurePdfFile` in tests.
- Reader progress needs no data change: `LibraryRepository.setProgress(id, (page+1)/pageCount, anchor = pageIndex)` already writes Room + op.
- Open in another app (FileProvider) is UI-side: use `pdfFile(itemId)`; no FileProvider was added.

## Database / network
- Room v2 (`MIGRATION_1_2`, `ALL_MIGRATIONS`, registered in `DatabaseModule`; schemas `1.json`, `2.json`): `items.kind TEXT NOT NULL DEFAULT 'ARTICLE'`, `file_name`, `file_size`. Test: `core:database` `MigrationTest` (builds a v1 file from `1.json`, opens through Room).
- `SrokaApi.uploadPdf(file, fileName, tags, source, onProgress)`; `ItemDto.kind/fileName/fileSize`; `ContentUrlsDto.documentUrl`; `PdfUploadResponseDto`. Upload client has 120 s read/write timeouts.
- Tests: `PdfDataTest` (sync mapping, upload error mapping + request shape, WorkInfo mapping, enqueue checks, ContentStore PDF paths), `PdfDtoTest`, `MigrationTest`.

## Open items
- No UI: library "Add PDF" picker, share-sheet/drag-drop entry points, PDF row tile, PdfRenderer reader, snackbar strings (all the UI agent's). Share/drop callers just pass content URIs to `PdfUploader.enqueue` (grant read permission is the activity's job; the copy happens inside `enqueue`, so call it before the activity finishes).
- Upload worker is not foreground/expedited: a very slow upload can be stopped at WorkManager's ~10 min execution limit and restarts from scratch.
- Server `text.txt` is not downloaded, so PDF body text is not in offline FTS (title/file name/tags/excerpt are searchable).
- `item.refresh` / `item.add` ops for PDF items are not special-cased locally (server rules in the spec apply).
- The server contract was coded from the spec (no live server test); verify `409 storage_full` code string and `202 {item, created}` against `docs/api.md` when the API lands.
