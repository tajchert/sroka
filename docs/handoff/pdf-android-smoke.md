# Android PDF smoke test (emulator Pixel_10_Pro_Fold, backend localhost:8787)

1. Sign in (android-pdf@example.com, OTP from log): PASS
2. Add -> "Choose PDF file" (menu label differs from "Add PDF") -> picker -> upload; item with PDF tile, "PDF · 17 KB"; server `POST /v1/items/pdf 202`: PASS
3. PdfRenderer reader (2-page and 7-page PDFs): scroll PASS; page indicator updates (n / 7); reopen after force-stop restores page (4/7) PASS; double-tap + drag no crash PASS. Real pinch NOT tested (adb input has no multitouch).
   - Minor: position is saved with a delay. Scrolled to 6/7, force-stopped ~2 s later, reopened at 2/7. With a 5 s wait it restored fine.
4. Share to Sroka from Files app (DocumentsUI): new PDF uploads (202, item appears) PASS. Re-sharing same file: no second item, server returns 202 PASS. The "Already in Sroka" message (string feature_library_snack_pdf_duplicate) was NOT observed in the share sheet; the sheet just closed. Inconclusive.
   - `am start ... SEND` from adb shell with content://media/external/file/23: SecurityException (shell cannot grant the URI), sheet shows "Couldn't add PDF"; harness limit, not an app bug. It left a persistent failed row "PDF not added / 23: Something went wrong" (Dismiss/Retry) in the library; the row text starts with the raw URI id "23:" (cosmetic).
5. Reader overflow: "Share PDF" opens chooser (Sroka, Quick Share, Drive...) PASS; "Open with another app" opened the Drive PDF viewer directly (single handler, no chooser) PASS.
6. Offline (`adb reverse --remove-all`) during upload: "Uploading 1 PDF" shown, no POST; after restoring reverse the upload completed (POST 202) and item appeared: PASS
7. `adb logcat -b crash -d` empty, no ANR: PASS

Screenshots skipped (multi-display adb screencap returned text warning); UI judged via uiautomator dumps.
