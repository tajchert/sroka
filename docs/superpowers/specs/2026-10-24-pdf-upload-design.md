# PDF upload — design and rulings (decisions D12)

Binding for every agent working on this feature; overrides individual plans. Contract code is already on branch
`feat/pdf` in `packages/shared` (model.ts `ItemKind`/`kind`/`fileName`/`fileSize`, parse.ts `ParseJob.pdf` + `PDF_FILE`,
limits.ts `maxPdfBytes`/`maxPdfStorageBytes`/`maxFileNameLength`, api.ts `ContentUrlsResponse.documentUrl`,
content-sign.ts `buildContentUrls({…, pdf})`). Don't change those shapes without updating this doc.

## Intent
Users drop or pick PDF files on the web app and on Android. Each PDF becomes a normal library item (tags, archive,
favorite, delete, search, sync) whose content is the **original file**, stored privately in R2 and opened as a PDF
(option A). No reflowed "reader view" for PDFs now; the original stays the source of truth so one can be added later.

Non-goals: OCR, PDF reader view, thumbnails of the first page, extension support, other file types, PDF annotations.
Anti-goals: losing or altering the original file; PDFs reachable without a signed URL; a PDF item that can't be opened
because text extraction failed.

## Data model (shared, done)
- `Item.kind: "article" | "pdf"` (existing items = `"article"`), `Item.fileName: string|null`, `Item.fileSize: number|null`.
- Item `url` of a PDF = `${APP_ORIGIN}/pdf/{sha256hex}` (sha256 of the file bytes, lowercase hex). It is the dedupe key:
  dropping the same file again re-adds the existing item (Pocket "readd" semantics, `created:false`).
- Content: `contentPrivate: true`, content dir `private/{userId}/{contentId}/`, original at `document.pdf` (`PDF_FILE`),
  optional `text.txt` (extracted text). No `article.html`, no `package.zip`.
- `siteName` = `"PDF"` (lists show it where they show the domain); `wordCount`/`readingMinutes`/`excerpt`/`author`/`lang`
  from extraction when available.

## API (`workers/api`)
### `POST /v1/items/pdf` — upload
- Body = raw PDF bytes, `Content-Type: application/pdf`, `Content-Length` required (missing → `411 length_required`).
- Query: `name` (original file name, required, trimmed, truncated to `LIMITS.maxFileNameLength` keeping `.pdf`),
  `tag` (repeatable, optional), `source` (`ItemSource`, default `"api"`; web sends `"web"`, Android `"share"`).
- Size: `Content-Length` > `LIMITS.maxPdfBytes` (50 MiB) → `413 payload_too_large` before reading; also enforce while streaming.
- Not a PDF: first bytes must contain `%PDF-` within the first 1024 bytes → `415 unsupported_media_type`; nothing stays in R2.
- Flow: `contentId = uuidv7()`; stream the body into R2 `private/{userId}/{contentId}/document.pdf`
  (`httpMetadata.contentType = application/pdf`) while hashing (`crypto.DigestStream("SHA-256")` + tee, or a
  `TransformStream` that hashes and counts — implementer's choice, but **never buffer the whole file twice**; one
  `arrayBuffer()` of ≤ 50 MiB is acceptable if streaming proves impractical). Then one DO RPC
  `addPdf(deviceId, {itemId, url, title, fileName, fileSize, contentId, tags, source, at})` that, in one transaction:
  1. duplicate (live item with the same url hash) → re-add it like `item.add` `onDuplicate:"readd"` (union tags,
     savedAt bump, unread), return `{item, created:false, duplicate:true}`; the route then deletes the just-written object.
  2. storage check: `SUM(file_size)` of live pdf items + `fileSize` > `LIMITS.maxPdfStorageBytes` → `{error:"storage_full"}`;
     route deletes the object, responds `409 {"error":"storage_full"}`.
  3. else insert the item exactly like `item.add` (same row defaults, FTS row, tags, seq bump, sync-visible), plus
     `kind='pdf'`, `file_name`, `file_size`, `content_id = contentId`, `content_private = 1`, `site_name = 'PDF'`,
     provisional title = file name without `.pdf`, `parse_status='pending'`, `parse_gen += 1`, and return a ParseJob
     `{userId, itemId, url, parseGen, pdf:{contentId}}` (subject to the parse budget like other jobs; over budget → swept later).
- Response `202 {"item", "created"}` (`CreateItemResponse`). Errors as above plus `400 invalid_request`.
- A PDF item is **readable as soon as it exists** (`contentId` set even while `parseStatus` is `pending`).
  Clients must not wait for parsing before opening a `kind:"pdf"` item.
- Ops over sync: an `item.add` op never creates a PDF; PDFs only come from this endpoint. All other ops
  (status, favorite, tags, title, progress, delete) work unchanged on PDF items.

### Other API changes
- DO schema v4: `items.kind TEXT NOT NULL DEFAULT 'article'`, `items.file_name TEXT`, `items.file_size INTEGER`;
  rows → wire (`rows.ts`), pull, list, get, export JSON include the fields.
- `item.refresh` on a pdf item: re-run extraction only — job `{…, pdf:{contentId}, force:true}`; never fetch the URL,
  never delete the content dir. Requires the stored content id.
- `item.delete` already deletes the private content dir → the PDF goes with it. Account deletion wipe already covers `private/`.
- `markParsed` for a pdf item: accept only `contentId === items.content_id` and `contentPrivate:true` (else `ok:false`);
  same content id means "no content change" → must not delete the dir. A `failed` result leaves the item readable.
- `GET /v1/items/:id/content`: for pdf items `documentUrl` = signed `…/document.pdf`; `articleUrl`/`packageUrl` still
  present (they 404) to keep the response shape. Articles: `documentUrl: null`.
- Content route: `.pdf` → `Content-Type: application/pdf`, `Content-Disposition: inline; filename="document.pdf"`.
  Keep `nosniff`, `private, no-store`, CORS echo of `APP_ORIGIN`/`DEV_ORIGINS`. The CSP `sandbox` directive stops
  Chrome's built-in PDF viewer when the signed URL is opened directly ("Open in new tab", `/pdf/:sha` redirect). For
  `.pdf` responses only, drop `sandbox` and use `Content-Security-Policy: default-src 'none'; object-src 'none'; frame-ancestors 'none'`
  as the starting point; if Chrome still refuses to render it, loosen only as far as needed and document the final
  header in docs/api.md §10 (the content host has no cookies, so the risk is limited). The web reader does not depend on
  this: it shows a blob URL. HTML files keep the existing CSP unchanged.
- `GET /pdf/:sha256` on the app host (APP_ORIGIN): session cookie → find the live item with that canonical URL → `302`
  to its signed `documentUrl`; no session → `302 /app/` (sign in); not found → `404`. Makes the item URL a working
  "open original" link for old clients and the extension. `/pdf/*` must reach the Worker before static assets
  (check `run_worker_first` in wrangler.jsonc, decisions D3/D8).
- `/v1/me` stats may add `pdfBytes` (optional, not required).
- `ParseJob.pdf` jobs from the alarm sweep (`sweepStalePending`) must keep `pdf` (re-derive from kind + content_id).
- Update `docs/api.md` (new §5.8, item fields in §4.1, §9 pdf jobs, §10 headers, §14 limits) in the same branch.

## Parser (`workers/parser`)
- Job with `pdf` → `parseWanted` check, read `private/{userId}/{contentId}/document.pdf` from R2, extract with
  **`unpdf`** (pdf.js serverless build, works in Workers; add it as a parser dependency): metadata `Title`/`Author`/
  `Language`, page count, text. Caps: first 300 pages, 2 MB of text; stop early when over.
- Result `status:"ok"`, `contentId: pdf.contentId`, `contentPrivate: true`, `title` = metadata Title if it is
  non-empty, not a file path, and not a generic producer string (e.g. "Untitled", "Microsoft Word - x.docx" → strip the
  "Microsoft Word - " prefix and extension) else `null` (keeps the provisional file-name title); `author`, `lang`;
  `excerpt` = first ~300 chars of normalized text; `wordCount`/`readingMinutes` (`readingMinutes()` from shared);
  `siteName: "PDF"`. Write `text.txt` into the same dir (best effort).
- Extraction failure, encrypted PDF, or no text (scans) → still `status:"ok"` with null metadata and
  `error: "pdf_no_text"` / `"pdf_encrypted"` / `"pdf_extract_failed"`, so the item stays readable and isn't shown as failed.
  Only R2 read failures are transient (retry like other jobs).
- On `markParsed` → `ok:false`: for pdf jobs delete **nothing** (every job of the item writes the same `text.txt` key, so a
  stale/duplicate delivery could remove the accepted result's text; an orphan text.txt is collected with the dir).
- Originals over 20 MiB (`obj.size`, checked before reading the body) are not extracted: `status:"ok"`,
  `error:"pdf_too_large"`, null metadata (item stays readable).
- Never touches the shared D1 `content` cache; no `content` row; `parse_attempts` row with `method:"pdf"`
  (extend the method enum), `url` NULL (private).
- Bump nothing in PARSER_VERSION (article output unchanged).

## Web (`apps/web`)
- Library: drag a PDF (or several) anywhere onto the library page → full-page drop overlay ("Drop PDF to save") →
  upload each file; plus an "Add PDF" button/file picker (`accept="application/pdf"`, multiple) next to the save-URL
  input. Non-PDF files are ignored with a toast. Files > 50 MiB rejected client-side with a message.
- Upload with progress (XHR `upload.onprogress`), one inline progress row per file, error states mapped from API
  errors (413, 415, 409 storage_full, offline). On success the item appears at the top of My List (invalidate/patch cache).
- `ItemRow`: PDF items show a PDF badge/icon instead of the domain thumbnail, `siteName` "PDF" and file size.
- Reader: `kind:"pdf"` → get `/content` → `fetch(documentUrl)` (CORS) → `Blob` → object URL → full-height `<iframe>`
  showing the browser's PDF viewer (`#page={progressAnchor+1}` when an anchor exists). Toolbar keeps archive / favorite /
  tags / delete, plus "Download" (same blob, `download=fileName`) and "Open in new tab". Revoke the object URL on leave.
  Opening sets `lastReadAt` via a progress PATCH only if progress is 0 (`progress: 0.01`) so the item counts as started.
  Don't wait on `parseStatus` for PDFs.

## Android (`apps/android`)
- Add PDF from: (1) a "Add PDF" action in the library (Storage Access Framework `OpenMultipleDocuments("application/pdf")`),
  (2) the share sheet (`ShareActivity` also accepts `application/pdf`, `SEND` and `SEND_MULTIPLE`),
  (3) the existing foldable drag-to-save target accepting `application/pdf` clip items.
- Upload: copy the file into app storage (`filesDir/pdf-uploads/`), enqueue a unique WorkManager upload job
  (network constraint, exponential backoff, keeps the file until success or a permanent 4xx). Uploads are REST
  (`POST /v1/items/pdf`), not sync ops (an op can't carry a file). On success run a sync pull so the item arrives
  through the normal path; delete the temp copy. Show progress/state via a snackbar and a small "Uploading N PDFs" row
  in the library while jobs exist; permanent errors (413/415/409) as a typed error message.
- Room: migration adding `kind`, `fileName`, `fileSize` to the item entity (default `article`), schema exported, migration test.
- Reader: `kind == "pdf"` → native viewer with `android.graphics.pdf.PdfRenderer` (vertical list of page bitmaps,
  pinch-zoom, rendered lazily at screen width × density, bitmaps recycled). The file comes from ContentStore: download
  `documentUrl` into the offline content dir (same offline/download policy as article packages, WorkManager, progress).
  Progress = `(page+1)/pageCount`, `progressAnchor = page index`, written like article progress (local-first + op).
  Actions: share/open with another app (FileProvider), plus existing archive/favorite/tags/delete.
- Library list: PDF items show a PDF icon tile instead of the lead image, "PDF · 2.3 MB" subtitle.
- Icons only via `SrokaIcons` (add a symbol to `scripts/gen-icons.py`, e.g. `picture_as_pdf`, `upload_file`).

## Builder's calls (made by Claude, flag in review)
- 50 MiB per file, 2 GiB per user; dedupe by file hash; PDF items are `contentPrivate` always.
- `siteName = "PDF"`; title from file name, replaced by PDF metadata title when meaningful; a user title always wins.
- Extraction failures are not parse failures (status `ok` + `error` code).
- Web uses the browser's built-in viewer via a blob URL (no pdf.js in the bundle).

## Work split (each on its own branch off `feat/pdf`, merged back into `feat/pdf`)
| Part | Branch | Owns |
|---|---|---|
| API | `feat/pdf-api` | `workers/api/**`, `docs/api.md` |
| Parser | `feat/pdf-parser` | `workers/parser/**` (+ `packages/extractor` only if needed) |
| Web | `feat/pdf-web` | `apps/web/**` |
| Android | `feat/pdf-android` | `apps/android/**` |
Nobody edits `packages/shared` except to fix a bug in the contract above (then say so in the handoff note).
Each part writes `docs/handoff/pdf-<part>.md` (what was done, how verified, open items) and commits.
