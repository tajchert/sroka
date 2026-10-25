# PDF first-page previews — design

Extends `docs/superpowers/specs/2026-10-24-pdf-upload-design.md` (D12), whose non-goal "thumbnails of the first page"
this lifts. Binding for this feature.

## Intent
PDF items in the web and Android library lists show a picture of their first page where articles show their lead
image, instead of the generic PDF tile. It only needs to look roughly like the first page: a small, cropped, lossy
image is fine.

Goals: new PDF uploads from web and Android get a preview; every client that lists the item shows it.
Non-goals: previews for PDFs uploaded before this ships (they keep the PDF tile, no backfill); server-side rendering;
previews of later pages; preview in the reader.
Anti-goals: a PDF upload that fails or slows noticeably because the preview failed; the preview blocking the item
from appearing; a preview reachable without a signed URL.

## How it works (decided)
The **uploading client renders page 1** (it already has the file), then sends the image in a second request after
the PDF upload succeeds. The server stores it as the item's lead image in the private content dir, so it travels
through the existing `leadImageKey`/`leadImageUrl` path to every client.

### Image
- Page 1 rendered at **480 px wide** (height from the page aspect ratio, capped at 2× the width; crop the bottom if
  taller), white background (PDF pages may be transparent).
- Encoding: WebP lossy quality ~0.75. Web falls back to JPEG when the browser can't encode WebP (`canvas.toBlob`
  returns a non-WebP blob, e.g. Safari). Typical size 20–60 KB.
- Lists crop it to the tile with `object-cover` / `ContentScale.Crop`, aligned to the **top** of the page.

### API (`workers/api`)
`PUT /v1/items/:id/thumbnail`
- Body: raw image bytes, `Content-Type` `image/webp` or `image/jpeg`; `Content-Length` required (411), max
  **512 KiB** (413). Magic bytes must match the type (`RIFF....WEBP` / `FF D8 FF`) else `415 unsupported_media_type`.
- Item must be live and `kind:"pdf"` with a `contentId`: unknown/deleted → `404 not_found`, article → `409 not_pdf`.
- Writes R2 `private/{userId}/{contentId}/thumb.webp` (or `thumb.jpg`), `httpMetadata.contentType` set, then a DO RPC
  `setPdfThumbnail(itemId, key)` that sets `lead_image_key` and touches the item (seq bump, so sync pull carries it).
  If the key changes extension, delete the old object (best effort). Replacing an existing thumbnail is allowed
  (idempotent PUT).
- Response `200 {"item"}` with a freshly signed `leadImageUrl`.
- Content route `TYPES` gains `jpg: "image/jpeg"`.
- **`markParsedPdf` must not overwrite `lead_image_key`** (today it sets `result.leadImageKey ?? null`, which would
  wipe a thumbnail uploaded before parsing finished). PDF parse results never carry a lead image; drop that column
  from the PDF update.
- Rate limiting / auth: same middleware as other `/v1/items/*` writes.
- Document in `docs/api.md` (new §5.x next to the PDF upload, §10 content types).

### Web (`apps/web`)
- On upload: after `POST /v1/items/pdf` succeeds and the returned item has `leadImageKey === null` (a duplicate that
  already has one is skipped), render page 1 and `PUT` the thumbnail. Fire-and-forget: errors are logged via the
  existing client error path, never shown to the user; the upload row is already done.
- Renderer: `pdfjs-dist` (pinned, lazy `import()` only when a PDF is uploaded, with its worker as a separate Vite
  asset). This is an exception to "don't add deps", approved by the user for this feature. Render with a 10 s timeout;
  skip encrypted/broken files silently.
- Update the item in the TanStack cache with the response so the preview appears without a refetch.
- `ItemRow`: PDF items with `leadImageUrl` show the image (`object-cover object-top`); without it, today's PDF tile.
  Keep the "PDF" label available (e.g. small badge on the image corner) so a PDF is still recognisable.

### Android (`apps/android`)
- After a successful upload in the WorkManager upload job (`PdfUploadProcessor` `Uploaded`, not duplicate-with-thumb):
  render page 1 with `PdfRenderer` from the local temp copy (before it is deleted), compress `WEBP_LOSSY`, `PUT` it.
  Best effort: one attempt, any failure is logged and ignored; it never turns the upload into a retry or failure.
- Save the same image as the item's local thumbnail file (`ContentPaths` thumb path, the `content_files.thumbPath`
  row field) so the uploading device shows it immediately without a download.
- Other devices: `ContentStoreImpl.downloadPdfLocked` downloads the thumbnail like article downloads do
  (`downloadThumbnail(itemId, urls.baseUrl, leadImageKey, gen)` after the PDF arrives, and
  `retryMissingThumbnail` on the `AlreadyCurrent` path, so a thumbnail that arrives after the PDF was downloaded is
  still fetched on the next download pass).
- `ItemRow.Thumbnail`: PDF with `thumbnailPath` → `AsyncImage` cropped, top-aligned (`Alignment.TopCenter`) with a
  small PDF badge; no path → today's PDF icon tile. Update screenshot fixtures/references.
- `SrokaApi` gains `uploadThumbnail(itemId, bytes, contentType)`; network test for the request shape.

## Left to the builder
- Exact pdf.js integration in Vite (worker URL import style), canvas sizing code, badge styling.
- Where the Android render helper lives (shared with `feature/reader` `PdfDocument` or a small copy in core:data).
- Test coverage beyond: API route (types, size, magic bytes, 404/409, markParsed keeps the key), DO store, web
  ItemRow both states, Android processor + ContentStore thumbnail path + screenshot.
