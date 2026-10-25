# PDF First-Page Previews Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** New PDF uploads from web and Android get a first-page preview image that the library lists on both clients show.

**Architecture:** The uploading client renders page 1 and `PUT`s it to `/v1/items/:id/thumbnail`. The API stores it as
`thumb.webp`/`thumb.jpg` in the item's private content dir and sets `lead_image_key`, so the existing
`leadImageKey`/`leadImageUrl` path carries it everywhere.

**Tech Stack:** Hono + Durable Object SQLite (workers/api), React + TanStack Query + pdfjs-dist (apps/web), Kotlin + PdfRenderer + OkHttp + Room (apps/android).

**Spec:** `docs/superpowers/specs/2026-10-25-pdf-preview-design.md`

## Global Constraints
- Thumbnail body: `image/webp` or `image/jpeg`, `Content-Length` required (411), max 512 KiB (413), magic bytes `RIFF....WEBP` / `FF D8 FF` else 415 `unsupported_media_type`.
- Render page 1 at 480 px wide, height capped at 2× width (crop bottom), white background, WebP lossy ~0.75 (web: JPEG fallback when `toBlob` yields non-WebP).
- R2 key `private/{userId}/{contentId}/thumb.webp` or `thumb.jpg`; `lead_image_key` = `"thumb.webp"`/`"thumb.jpg"`.
- Preview failure never fails or retries an upload and is never shown to the user.
- No backfill for existing PDFs.
- Logging: `log` from `@sroka/shared` (never `console.*`), Android `Log` as existing code does. Never log file names.
- Web: `pdfjs-dist@6.3.289` is the only new dependency, lazy-loaded.
- Android: icons only via `SrokaIcons`; strings in resources.

## Review Focus
1. Thumbnail PUT racing the parser: parse finishes after the PUT → `markParsedPdf` must keep `lead_image_key` (Task 1 test).
2. Item deleted (or content id changed) between the route's R2 write and the DO commit → 404 and the just-written object is deleted (Task 2 test).
3. Duplicate upload (`created:false`) of a PDF that already has a preview → clients skip rendering (Task 3 + Task 4 tests).
4. Encrypted / corrupt PDF on the client → renderer returns null, no PUT, upload row still "done" (Task 3 + Task 4 tests).
5. Android device that downloaded the PDF before `leadImageKey` arrived → thumbnail fetched on the next download pass (Task 5 test).

---

### Task 1: DO store — set PDF thumbnail, keep it across parses

**Files:**
- Modify: `workers/api/src/do/store.ts` (`markParsedPdf` ~line 822; add method after `addPdf`)
- Modify: `workers/api/src/library-do.ts` (RPC next to `addPdf` ~line 287)
- Test: `workers/api/test/do/library.test.ts`

**Interfaces:**
- Produces: `Store.setPdfThumbnail(itemId: string, contentId: string, key: string): { ok: true; previousKey: string | null } | { ok: false }` — ok only when the item is live, `kind='pdf'`, `content_id = contentId`; sets `lead_image_key`, `ctx.touchItem`.
- Produces: `LibraryDO.setPdfThumbnail(itemId: string, contentId: string, key: string): Promise<{ ok: true; item: Item; previousKey: string | null } | { ok: false }>` (item signed via `signOne`).
- Produces: `LibraryDO.getItem` already exists if used by routes; route needs `kind` + `contentId` of a live item (use the existing item read RPC the routes use; add `getItemForUser(itemId)` only if none exists).

- [ ] **Step 1: Failing tests** in `library.test.ts`:
  - `setPdfThumbnail sets leadImageKey and bumps seq`: after `addPdf`, call it with the item's contentId and `"thumb.webp"` → `ok`, `getItem().leadImageKey === "thumb.webp"`, `leadImageUrl` ends with `/thumb.webp`, a pull from the prior cursor contains the item.
  - `setPdfThumbnail refuses article, deleted item, wrong contentId` → `{ok:false}` each.
  - `markParsed of a pdf keeps an uploaded thumbnail`: setPdfThumbnail, then `markParsed` with an ok PDF result (no `leadImageKey`) → `leadImageKey` still `"thumb.webp"`.
  - `setPdfThumbnail returns previousKey` when replacing `thumb.webp` with `thumb.jpg`.
- [ ] **Step 2:** `npm test -w @sroka/api -- test/do/library.test.ts 2>&1 | tail -30` → new tests FAIL.
- [ ] **Step 3:** Implement. In `markParsedPdf` remove `lead_image_key = ?` and its bind value.
- [ ] **Step 4:** Same command → PASS; `npm run typecheck -w @sroka/api`.
- [ ] **Step 5:** Commit `feat(api): DO setPdfThumbnail; PDF parse keeps lead image`.

### Task 2: API route `PUT /v1/items/:id/thumbnail` + docs

**Files:**
- Modify: `workers/api/src/routes/items.ts` (after the `/pdf` route)
- Modify: `workers/api/src/routes/content.ts` (`TYPES` add `jpg: "image/jpeg"`)
- Modify: `docs/api.md` (new subsection after the PDF upload §5.8; §10 content types)
- Test: `workers/api/test/routes-library/pdf.test.ts`

**Interfaces:**
- Consumes: Task 1 `LibraryDO.setPdfThumbnail`.
- Produces: `PUT /v1/items/:id/thumbnail` → `200 {"item": Item}`; errors `411 length_required`, `413 payload_too_large`, `415 unsupported_media_type`, `404 not_found`, `409 not_pdf`.

- [ ] **Step 1: Failing tests** in `pdf.test.ts` (reuse its upload helper to create a PDF item):
  - webp body → 200, `item.leadImageKey === "thumb.webp"`, R2 has `private/{u}/{contentId}/thumb.webp` with contentType `image/webp`.
  - jpeg body → `thumb.jpg`; then webp body → `thumb.webp` and `thumb.jpg` deleted from R2.
  - no Content-Length → 411; 600 KiB → 413; `image/png` or webp header with JPEG bytes → 415.
  - unknown id → 404; article item → 409 `not_pdf`; unauthenticated → 401.
  - item deleted before commit (stub/spy so `setPdfThumbnail` returns `{ok:false}`) → 404 and no `thumb.*` left in R2.
  - content route serves `thumb.jpg` with `Content-Type: image/jpeg`.
- [ ] **Step 2:** `npm test -w @sroka/api -- test/routes-library/pdf.test.ts 2>&1 | tail -30` → FAIL.
- [ ] **Step 3:** Implement: validate headers/length, read body (`arrayBuffer`, enforce ≤ 512 KiB actual), check magic bytes vs type, look up item (404 / 409), `CONTENT.put` with contentType, `setPdfThumbnail`; `ok:false` → delete object, 404; `previousKey` with different name → delete old object (best effort, `waitUntil`). Same auth/rate-limit middleware as other item writes. Write the api.md section.
- [ ] **Step 4:** Same command → PASS; `npm test -w @sroka/api 2>&1 | tail -15`; typecheck.
- [ ] **Step 5:** Commit `feat(api): PUT /v1/items/:id/thumbnail for PDF previews`.

### Task 3: Web — render on upload, show in ItemRow

**Files:**
- Create: `apps/web/src/lib/pdf-thumb.ts` (lazy pdfjs render)
- Modify: `apps/web/package.json` (`pdfjs-dist` `6.3.289` exact), `apps/web/src/lib/api.ts` (thumbnail call), `apps/web/src/lib/uploads.ts` (after success), `apps/web/src/components/ItemRow.tsx` (thumbnail branch)
- Test: `apps/web/src/lib/uploads.test.tsx`, new `apps/web/src/components/ItemRow.test.tsx`

**Interfaces:**
- Consumes: Task 2 endpoint.
- Produces: `renderPdfThumbnail(file: Blob): Promise<Blob | null>` (null on any error or 10 s timeout; dynamic `import("pdfjs-dist")`, worker via `pdfjs-dist/build/pdf.worker.min.mjs?url`); `putThumbnail(itemId: string, blob: Blob): Promise<Item>` in api.ts.

- [ ] **Step 1: Failing tests** (mock `../lib/pdf-thumb.ts`):
  - uploads: after a successful upload whose item has `leadImageKey: null`, `putThumbnail` called once with the item id and the rendered blob; cached item updated with the response.
  - uploads: `created:false` item with `leadImageKey: "thumb.webp"` → renderer not called.
  - uploads: renderer returns null, or `putThumbnail` rejects → upload row still `done`, no error toast.
  - ItemRow: pdf item with `leadImageUrl` renders `<img>` with that src and a "PDF" badge; pdf item without it renders today's PDF tile.
- [ ] **Step 2:** `npm test -w @sroka/web 2>&1 | tail -30` → FAIL.
- [ ] **Step 3:** Implement. `npm install pdfjs-dist@6.3.289 -w @sroka/web --save-exact`. Render: page 1, scale to 480 px width, canvas height `min(h, 960)`, fill white first, `toBlob("image/webp", 0.75)`, if result type isn't webp re-encode `image/jpeg` 0.75. Image classes `h-full w-full object-cover object-top`. Errors go to the existing client error reporting (`lib/error-reporting.ts`), not toasts.
- [ ] **Step 4:** tests PASS; `npm run typecheck -w @sroka/web`; `npm run build -w @sroka/web 2>&1 | tail -15` shows pdfjs in a separate chunk (main bundle size not grown by ~1 MB).
- [ ] **Step 5:** Commit `feat(web): first-page previews for uploaded PDFs`.

### Task 4: Android — render and upload after the PDF upload

**Files:**
- Modify: `apps/android/core/network/src/main/kotlin/app/sroka/core/network/SrokaApi.kt`, `OkHttpSrokaApi.kt` (+ fake in `core/testing/.../fake/` if `SrokaApi` has one)
- Create: `apps/android/core/data/src/main/kotlin/app/sroka/core/data/upload/PdfThumbnailRenderer.kt`
- Modify: `apps/android/core/data/src/main/kotlin/app/sroka/core/data/upload/PdfUploadProcessor.kt`, `PdfUploadWorker.kt`
- Test: `core/network/src/test/.../OkHttpSrokaApiTest.kt`, `core/data/src/test/.../PdfDataTest.kt`

**Interfaces:**
- Consumes: Task 2 endpoint.
- Produces: `SrokaApi.uploadThumbnail(itemId: String, bytes: ByteArray, contentType: String = "image/webp"): ApiResult<ItemDto>`; `fun interface PdfThumbnailRenderer { fun render(file: File): ByteArray? }` with the `PdfRenderer` implementation (480 px wide, height ≤ 960, white fill, `Bitmap.CompressFormat.WEBP_LOSSY` 75, bitmap recycled, returns null on any exception); `UploadOutcome.Uploaded` gains `hasThumbnail: Boolean` (from `item.leadImageKey != null`).

- [ ] **Step 1: Failing tests:**
  - OkHttpSrokaApiTest: `uploadThumbnail` sends `PUT /v1/items/{id}/thumbnail`, `Content-Type: image/webp`, body bytes, parses item.
  - PdfDataTest: after `Uploaded(hasThumbnail=false)` the worker/processor calls the renderer and `uploadThumbnail` before queuing sync; `hasThumbnail=true` → renderer not called; renderer null or `uploadThumbnail` HttpError/NetworkError → upload still success, no retry. (Inject the renderer as a fake; real `PdfRenderer` isn't exercised in JVM tests.)
- [ ] **Step 2:** `cd apps/android && ./gradlew :core:network:testDebugUnitTest :core:data:testDebugUnitTest --console=plain 2>&1 | tail -30` (JDK 21) → FAIL.
- [ ] **Step 3:** Implement. The render uses the local temp copy before it is deleted; one attempt, logged with `Log.w` on failure.
- [ ] **Step 4:** Same command → PASS.
- [ ] **Step 5:** Commit `feat(android): upload first-page preview after PDF upload`.

### Task 5: Android — download PDF thumbnails, show in list

**Files:**
- Modify: `apps/android/core/data/src/main/kotlin/app/sroka/core/data/content/ContentStoreImpl.kt` (`downloadPdfLocked` ~line 286)
- Modify: `apps/android/feature/library/impl/src/main/kotlin/app/sroka/feature/library/impl/list/ItemRow.kt` (`Thumbnail` ~line 127)
- Modify: `feature/library/impl/src/screenshotTest/.../LibraryFixtures.kt` (one PDF with a thumbnail) + references
- Test: `core/data/src/test/.../ContentStoreTest.kt`

**Interfaces:**
- Consumes: existing `downloadThumbnail(itemId, baseUrl, key, gen)`, `retryMissingThumbnail(leadImageKey, row, gen)`.

- [ ] **Step 1: Failing tests** in ContentStoreTest:
  - PDF item with `leadImageKey` → after download, `thumbPath` set and the file exists.
  - PDF already DOWNLOADED without thumb, item later gets `leadImageKey` → next download call (AlreadyCurrent path) fetches it.
  - Thumbnail fetch fails → PDF row still DOWNLOADED.
- [ ] **Step 2:** `./gradlew :core:data:testDebugUnitTest --console=plain 2>&1 | tail -30` → FAIL.
- [ ] **Step 3:** Implement: pass `leadImageKey` into `downloadPdfLocked`; keep `thumbPath`/`thumbAttempts` from `previous` in the row it writes; call `retryMissingThumbnail` on AlreadyCurrent and `downloadThumbnail` after a successful download (non-fatal, cancellation rethrown, same as articles). ItemRow: PDF with `thumbnailPath` → `AsyncImage` `ContentScale.Crop`, `alignment = Alignment.TopCenter`, small `SrokaIcons.PictureAsPdf` badge in a corner; else today's tile.
- [ ] **Step 4:** tests PASS; `./gradlew :feature:library:impl:updateDebugScreenshotTest` then `validateDebugScreenshotTest`; gate `./gradlew testDebugUnitTest lintDebug assembleDebug --console=plain 2>&1 | tail -30`.
- [ ] **Step 5:** Commit `feat(android): PDF thumbnails in the library list`; update `docs/ledger.md` with a line for the feature (not deployed).
