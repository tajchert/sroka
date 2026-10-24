# PDF upload — Android UI (handoff)

Branch `feat/pdf-android`, on top of the data layer (d31166e). Gate green: `testDebugUnitTest lintDebug assembleDebug` and `validateDebugScreenshotTest` (library, reader, app, designsystem). **Not run on a device/emulator** (none attached).

## Done
- Add PDF: the "Add link" dialog (FAB and rail) is now "Add link or PDF" with a "Choose PDF file" button (`OpenMultipleDocuments("application/pdf")`) -> `LibraryListViewModel.addPdfs` -> `PdfUploader.enqueue`.
- Share: `ShareActivity` + manifest accept `application/pdf` for SEND and SEND_MULTIPLE (`isPdfShare`/`sharedPdfUris`, ClipData fallback); `PdfShareHost`/`PdfShareViewModel` (bottom sheet, signed-out -> sign-in, typed failure, auto-dismiss 2.5 s). `enqueue` copies inside the activity lifetime.
- Drag-to-save: drop target also accepts `application/pdf` clips (`requestDragAndDropPermissions`, `extractDroppedPdfUris`).
- Upload feedback: `UploadCards` (Uploading N PDFs with size-weighted progress, failed card with typed message, Retry, Dismiss); snackbars for queued / done / duplicate / failed via `uploadEvents` (visible screen only; Done entries are `clearFinished()` after announcing, failures stay until Dismiss).
- Rows: PDF icon tile + "PDF · 2.4 MB" (decimal units) on phone and two-pane.
- Reader: `ReaderUiState.PdfReady`; VM resolves PDFs via `pdfFile`/`ensurePdfFile` (key stable so the download is not cancelled), typed errors + Try again; progress `(page+1)/count`, anchor = page index via `onPdfPage` -> `onProgress`. `PdfViewer`: PdfRenderer on a single render thread, lazy page list, leased LRU bitmap cache (48 MB, recycled only when unleased), pinch / double-tap zoom up to 4x, horizontal pan, page badge. Menu for PDFs: tags, Share PDF, Open with another app (FileProvider `${applicationId}.exports`, new `files-path articles/`), delete; archive/favorite as before. Tabletop layout is not used for PDFs (full width).
- Icon `PictureAsPdf` added via `scripts/gen-icons.py` (`UploadFile` already existed).
- Tests: `PdfUploadTest` (cards, size format, VM events), `PdfReaderTest`, `RefCountedCacheTest`, `PdfShareIntentTest` (Robolectric, helpers only); 3 new screenshot previews x 3 devices (PDF rows, uploading, failed).

## Open items
- Untested on device: SAF picker, share sheet, drag-drop, real PdfRenderer, FileProvider open/share.
- Retry on a failed card re-opens the file picker (the uploader has no retry; failed temp copies are deleted). Hidden for TOO_LARGE/NOT_PDF.
- Zoom scales the rendered bitmap (rendered at viewport width), so it blurs above ~1.5x; re-render at zoom level is a follow-up. Zoom is anchored to the top edge.
- Password-protected/corrupt PDFs show "Can't display" + Open with another app.
- No screenshot test of the reader (PdfRenderer does not render in previews); no UI test of the Hilt `ShareActivity` itself.
- Reader error strings for PDFs reuse article wording ("article could not be downloaded").
