# Google Play: Data safety (play flavor, `app.sroka` 1.5.0)

Answers for the form at Play Console > App content > Data safety. Checked against: `apps/android/app/src/play/AndroidManifest.xml`, `app/src/main/AndroidManifest.xml`, `app/src/play/kotlin/app/sroka/telemetry/FirebaseTelemetry.kt`, `core/domain/.../Telemetry.kt`, `docs/decisions.md` D15, `apps/web/privacy.html`.

## Overview questions
| Question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | Yes |
| Is all of the user data collected by your app encrypted in transit? | Yes. All traffic is HTTPS (`cleartextTrafficPermitted="false"` in release, `network_security_config.xml`; Firebase uses TLS). |
| Do you provide a way for users to request that their data be deleted? | Yes. In-app: Settings > Delete account (deletes account, library, uploaded files, sessions immediately). Web URL: `https://sroka.app/privacy#delete-account` (also covers email request to hello@sroka.app). |
| Independent security review | No (do not tick) |
| Committed to Play Families policy | No (target audience is adults) |

"Shared" means transfer to a third party. Cloudflare (hosting, storage, email delivery) and Google Firebase (Crashlytics, Analytics) process data on our behalf as service providers, which Google excludes from "sharing". So every type below is **Collected, not shared**. If you would rather be conservative about Firebase, see Mismatches in `store/README.md`.

## Data types (declare only these; everything else = not collected)

| Category > Type | Collected | Shared | Ephemeral? | Required or optional | Purposes |
|---|---|---|---|---|---|
| Personal info > Email address | Yes | No | No | Required (account) | App functionality, Account management |
| Personal info > User IDs | Yes (internal account id, session) | No | No | Required | App functionality, Account management |
| App activity > App interactions | Yes (only if user allows analytics: screens viewed, save/open/archive/favorite/search events, enum values only) | No | No | Optional (off until the first-run prompt is accepted; switch in Settings) | Analytics |
| App activity > Web browsing history | Yes (the URLs of pages the user chooses to save; it is their library, not their browsing) | No | No | Required for the core feature | App functionality |
| App activity > Other user-generated content | Yes (saved article copies, tags, favorites, archive state, reading progress, imported lists) | No | No | Required for the core feature | App functionality |
| Files and docs > Files and docs | Yes (PDFs the user shares to the app, stored in the user's private library) | No | No | Optional (only if the user saves PDFs) | App functionality |
| App info and performance > Crash logs | Yes (Firebase Crashlytics) | No | No | Optional (on by default; "Send crash reports" switch in Settings) | Analytics (diagnostics) |
| App info and performance > Diagnostics | Yes (Crashlytics: device model, OS and app version, stack trace) | No | No | Optional (same switch) | Analytics (diagnostics) |
| Device or other IDs > Device or other IDs | Yes: Firebase installation / app-instance ID (Crashlytics, and Analytics only after consent). Advertising ID is not collected; SSAID is disabled | No | No | Optional (tied to the same two switches) | Analytics (diagnostics) |

Not collected (answer No / leave unticked): name, address, phone, race, political or religious views, sexual orientation, other personal info, financial info (no payments), health and fitness, messages (SMS, email, in-app), photos/videos, audio, contacts, calendar, precise or approximate location (see Mismatches: server IP), search history (search runs on the device against the local database), installed apps, purchase history, "Other actions", "Other app performance data".

## Verification notes (device-ID questions)
- `play` manifest removes `com.google.android.gms.permission.AD_ID`, `ACCESS_ADSERVICES_AD_ID` and `ACCESS_ADSERVICES_ATTRIBUTION`, so the merged manifest has no AD_ID. In the Play Console "Advertising ID" declaration answer **No, the app does not use the advertising ID**.
- Meta-data: `firebase_analytics_collection_enabled=false`, `google_analytics_adid_collection_enabled=false`, `google_analytics_ssaid_collection_enabled=false`, all four default consent flags `false`. `ConsentApplier` turns analytics on only after the user allows it; `FirebaseTelemetry` grants only `ANALYTICS_STORAGE` and keeps ad storage, ad user data and ad personalization denied. Debug builds never send.
- Crashlytics collection is on by default (opt-out) per D15 and the privacy policy; the manifest has no `firebase_crashlytics_collection_enabled` default, and `ConsentApplier` applies the stored choice at app start.
- Events never carry URLs, titles, search terms, tag names, file names or email; no `setUserId`.

## Other relevant points (not form fields)
- `allowBackup=true`: the Room library DB may go to Google backup/device transfer; session token, shared prefs, offline articles, thumbnails and pending PDFs are excluded (`backup_rules.xml`, `data_extraction_rules.xml`). Google backup is the user's own and is not "collection" by us.
- Data retention (policy): server logs 30 days, crash reports 90 days, analytics 2 months, account data until deleted.
- Public articles: a clean copy of a public article may be cached on our servers and reused for other users who save the same link; never linked to who saved it. Users do not see each other's data.
