# store/ — Chrome Web Store and Google Play submission kit

Copy-paste text and images for both stores. The forms are legal declarations: every answer was checked against the code (see file headers for paths). Where code and privacy policy disagree it is listed in "Mismatches to resolve" below, not guessed.

## Contents
- `chrome-web-store/listing.md` name, summary, description, category, URLs
- `chrome-web-store/privacy-practices.md` single purpose, per-permission justifications, remote code, data-usage boxes, certifications
- `chrome-web-store/test-instructions.md` reviewer sign-in and test steps (placeholders only)
- `chrome-web-store/images/` icon, screenshots, promo tiles (images agent)
- `google-play/listing.md` name, short and full description, category, contact
- `google-play/data-safety.md` Data safety form answers
- `google-play/app-content.md` app access, ads, content rating, target audience, news, foreground service, release notes
- `google-play/images/` icon, feature graphic, screenshots (images agent)
- `upload/` gitignored: the extension zip, the `.aab`, and `sroka-fgs-datasync-demo.mp4` (foreground-service demo video for the Play declaration)

Secrets: never commit `REVIEW_EMAIL`/`REVIEW_OTP` values. Set them as API worker secrets (`wrangler secret put` in `workers/api`) and paste them only into the store consoles.

## Chrome Web Store upload checklist
Prereqs: developer account ($5 one-time), reviewer secrets set, extension built with `apps/extension/analytics.config.json` present (see extension CLAUDE.md), then `npm run zip -w @sroka/extension` (store build, no manifest `key`).
1. Dashboard > Add new item > upload `store/upload/srokaextension-0.6.0-chrome.zip`.
2. Store listing tab: name and summary are read from the manifest; paste description from `chrome-web-store/listing.md`; category Productivity; language English; upload icon 128x128, screenshots 1280x800, small promo 440x280, marquee 1400x560 (optional) from `chrome-web-store/images/`; homepage/support/privacy URLs from the listing file.
3. Privacy practices tab: single purpose, each permission justification, remote code = No, data-usage checkboxes and the three certifications, privacy policy URL, all from `privacy-practices.md`.
4. Distribution tab: visibility Public, regions all, no payments. Put the reviewer instructions from `test-instructions.md` in "Test instructions" (placeholders filled).
5. Save draft, submit for review. Expect extra review time for `scripting` + `tabs` + optional `https://*/*`.
6. Resolve the Mismatches below before submitting (at least: Google Fonts, policy wording).

## Google Play upload checklist
Prereqs: developer account, `./gradlew :app:bundlePlayRelease` (JDK 21) producing a release-signed `.aab` in `store/upload/`. Reviewer secrets set.
1. Create app: name from `google-play/listing.md`, default language English, App, Free.
2. Main store listing: short and full description, icon 512x512, feature graphic 1024x500, phone screenshots (2-8), optional tablet screenshots.
3. Store settings: category Productivity, tags, contact email, website.
4. App content (all of `google-play/app-content.md`): privacy policy URL, App access (reviewer sign-in), Ads = No, Content rating questionnaire, Target audience 18+, News app = No, Data safety (`data-safety.md`), Government = No, Financial = No, Health = No, Advertising ID = No, Foreground service declaration (dataSync, with the screen recording), account deletion URL.
5. Testing: Play requires a closed test with the required number of testers for new personal accounts before production; upload the `.aab` to Internal/Closed testing first.
6. Release notes for 1.5.0 (8) from `app-content.md`, review and roll out.

## After the first upload (post-upload steps)
1. Chrome Web Store assigns the extension id (Dashboard > item > Package). Add it:
   - DONE 2026-11-15 (store id `mgeodllnkiehnjbdogljfjgdbadjdblh`): API `EXT_ID` secret = `mgeodllnkiehnjbdogljfjgdbadjdblh,gmfnkkciofcaafddbcgphofiikmplema` and web `EXTENSION_IDS` include it.
2. When listings are live, replace the `https://sroka.app/#get` placeholders:
   - `apps/web/src/lib/links.ts` (`EXTENSION_URL`, `ANDROID_URL`; update the Onboarding test that expects `#get`)
   - landing `apps/web/index.html` (`href="#get"` on lines ~48, 67, 68, 220-222): Chrome Web Store URL, Google Play URL `https://play.google.com/store/apps/details?id=app.sroka`; remove or hide the "Download on the App Store" badge (no iOS app).
3. Update `docs/ledger.md` (ledger entry, store ids, dates).

## Mismatches to resolve
Items found while verifying; each needs an owner decision, the store text was NOT changed to hide them.

1. DONE 2026-11-15 (disclosed): the privacy policy now lists Google Fonts under "Services we use". Bundling the font in the extension is still nicer (next extension version). Was: **Extension loads Google Fonts, policy silent.** `apps/extension/entrypoints/popup/index.html` and `options/index.html` load Outfit CSS from fonts.googleapis.com / fonts.gstatic.com. This leaks the user's IP to Google when the popup opens, is not mentioned in the privacy policy (which lists Google only for Crashlytics/Analytics), and sits awkwardly with the Web Store's remote-resources rules and "no data collected before consent". Recommended: bundle the font in the extension (and note the same for the web app/landing, which also load it) or disclose it in the policy.
2. DONE 2026-11-15: policy now says crash reports include an app install ID. Was: **Crashlytics extra data.** Policy lists "device model, OS version, app version, stack trace". Crashlytics also uses a Firebase installation id (declared in Data safety as Device or other IDs). Add that to the policy text.
3. DONE 2026-11-15: policy no longer mentions location (logs keep only Cloudflare's data-centre code, not user location); IP is stated only for sign-in sessions/security, matching the forms. Was: **IP / location.** Policy says sessions store IP address and device type, and server logs contain "approximate location derived by our hosting provider". Data safety and the Web Store form do not declare Location/IP. Decide: if the IP-derived location counts for you, declare "Approximate location" in Play (collected, not shared, App functionality/Security) and tick Location in the Web Store; otherwise reword the policy.
4. **Extension "Web history".** Left unticked (only user-saved pages leave the browser; badge lookup is local and hashed). Play data safety does declare "Web browsing history" for saved URLs. The two forms differ by judgment; confirm or align (tick in both to be conservative).
5. **Extension sends the full rendered page by default** ("always capture" is on by default). The policy mentions "the page copy the browser extension captures", but the Web Store reviewers may question breadth. Store text states it plainly; consider a stronger first-run notice if review pushes back.
6. **Target age.** Policy says not for under 16; the store target audience is set to 18+. Consistent but not identical; either is acceptable, pick one.
7. **Landing page** shows a "Download on the App Store" badge (`apps/web/index.html`) and the description in some places mentions iOS; there is no iOS app. Remove before store review, as it contradicts the listings.
8. **Manifest description** ("Save pages to read later in Sroka") differs from the listing summary. Optional alignment.
9. **Not verified on a device.** The ledger says Android 1.4.0/1.5.0 and the consent flow were never run on a device; Data safety describes the code's intent. Run the consent flow once on a play-flavor build before submitting.
10. ~~Reviewer account / foreground-service recording missing.~~ DONE 2026-11-15: reviewer secrets set on the production API; `upload/sroka-fgs-datasync-demo.mp4` (86 s, play release 1.5.0) shows a 1,600-link Pocket import running in the "Importing links… N of 1600" foreground notification until "Import finished". Upload it (e.g. Google Drive, link visible to anyone) and paste the link in the Foreground service declaration.
