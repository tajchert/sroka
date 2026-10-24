# PDF upload - web (feat/pdf-web)

## Done
- `lib/pdf.ts`: pure helpers (file filtering/validation, size formatting, `#page=` fragment, upload URL, error mapping) + XHR `uploadPdf` (raw body, `application/pdf`, `?name&tag&source=web`, progress).
- `lib/uploads.ts` `usePdfUploads`: per-file rows (progress, processing, error with Retry/Dismiss), cache update via `promoteItem` (new/duplicate item moves to top; "Already saved" toast when `created:false`).
- Library: full-page drop overlay ("Drop PDF to save", aria-live announcement), "Add PDF" real button + hidden multi file input (`accept=application/pdf`), non-PDF toast, >50 MiB toast.
- `ItemRow`: PDF tile/badge, "PDF . size" instead of domain, no Fetching/parse badges for pdf.
- Reader: `kind:"pdf"` uses `components/PdfViewer.tsx` (content -> `fetch(documentUrl)` -> Blob -> object URL in iframe with `#page=progressAnchor+1`, revoked on unmount); Download (blob, `download=fileName`), Open in new tab, archive/favorite/tags/delete kept; article-only buttons hidden; progress PATCH 0.01 if progress is 0; does not wait on parseStatus.
- `itemTitle` falls back to `fileName`; `placeholderItem` and api test fixture got the new fields. `packages/shared` untouched.

## Verification
- `npm test -w @sroka/web` (all pass, incl. new pdf.test.ts and promoteItem test), typecheck, build green.

## Needs manual browser check against the real API
- Drag and drop overlay (incl. dragging non-file text does not trigger it), multiple files, picker via keyboard.
- Upload progress, 413/415/409 storage_full messages, duplicate re-add.
- Reader: blob fetch from the signed URL needs CORS (`APP_ORIGIN`) on the content host; iframe rendering in Chrome/Safari/Firefox; `#page=` resume; Download filename; Open in new tab (blob URL).
- Page progress is not tracked for PDFs on web (browser viewer gives no events); only the 0.01 "started" mark is written.
- Overlay is shown only on library routes (Library component), not on the reader/settings pages.
