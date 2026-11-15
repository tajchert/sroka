# Google Play: App content declarations

Play Console > Policy and programs > App content (and Release notes). Verified against `apps/android/app/src/main/AndroidManifest.xml`, `core/data/src/main/AndroidManifest.xml`, `docs/decisions.md`, `apps/web/privacy.html`.

## Privacy policy
`https://sroka.app/privacy`

## App access
Answer: **All or some functionality is restricted** (sign-in required). Provide:
```
Sroka needs an account; sign-in is by email one-time code (no password). Use this reviewer account:

Email: <REVIEW_EMAIL>
Code: <REVIEW_OTP>

Open the app, enter the email, press the button to send the code, then type the code above. The code is fixed for this account, so no email needs to arrive. Please request the code once; sending is rate limited.
After signing in: share a link from any app (Share > Save to Sroka) or open the library and save one, open it in the reader, and try Tags, Favorite and Archive. Settings has Export, Import and Delete account.
```
Mechanism: API secrets `REVIEW_EMAIL` / `REVIEW_OTP` make the one-time code for that exact address equal to `REVIEW_OTP` (`workers/api/src/auth.ts`). Set them as worker secrets before submission; paste the values only in the Play Console form, never in git. Same account as the Chrome test instructions.

## Ads
Answer: **No, my app does not contain ads.**

## Content rating (IARC questionnaire)
Category: **Utility, productivity, communication or other** (not a game, not a social app).
- Violence, blood, fear/horror, sexuality or nudity, profanity, controlled substances, gambling, simulated gambling: **No** to all (the app itself has no such content).
- User-generated content / user interactions: **No**. Users cannot share, publish, message or see other users' content. Saved items are private to the account (verified: no sharing feature in `docs/api.md`; a clean copy of a public article may be cached server-side and reused, but never shown as another user's content).
- Shares user's location with others: **No**. Digital purchases: **No**. Unrestricted web access: the reader shows the saved copy of web pages the user chose, not a browser. If the questionnaire asks about "web content", disclose that pages are third-party content saved by the user; this may raise the displayed rating slightly. Be honest rather than minimizing.
Expected result: Everyone / PEGI 3 or similar, possibly higher if web content is flagged.

## Target audience and content
- Target age group: **18 and over** only. Reason: general-audience utility, not designed for children; avoids the Families policy. The privacy policy says the service is not meant for children under 16, which is consistent (see Mismatches).
- Appeals to children: No.

## News app declaration
Answer: **My app is not a news app.** Sroka is a personal read-later tool: the user saves pages from any source; Sroka does not publish, curate or aggregate news, and has no editorial content. Category is Productivity, not News & Magazines.

## Government, financial, health, other declarations
- Government app: **No**.
- Financial features: **No** (no payments, no banking, no loans, no crypto).
- Health apps: **No** health features.
- COVID-19 contact tracing/status app: **No**.
- Social/dating, gambling, VPN, accessibility service, SMS/call log: **No** (none requested).

## Account deletion (Data safety > "Delete account URL")
- URL: `https://sroka.app/privacy#delete-account`
- In-app path: Settings > Delete account (immediate; deletes the library, uploaded files and sessions). If the user cannot sign in: email hello@sroka.app from the account's address (within 30 days). Server logs and crash reports expire by schedule (30 and 90 days).
- Data deletion option without deleting the account: not offered (answer "Delete account only" if asked; the user can delete items individually in the app).

## Permissions and special declarations
Merged manifest (`play` flavor): `INTERNET`, `ACCESS_NETWORK_STATE`, `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`; `AD_ID`, `ACCESS_ADSERVICES_*` removed. No location, contacts, camera, microphone, storage, SMS or accessibility permissions. minSdk 26, targetSdk 37. `allowBackup=true` with sensitive paths excluded.

### Foreground service permissions declaration (type: Data sync)
Used by WorkManager's `SystemForegroundService` (`foregroundServiceType="dataSync"`) in `ContentDownloadWorker` (downloads saved articles and images for offline reading) and `ImportProgressWorker` (import of links from Pocket, Instapaper or bookmarks). Paste:
```
Data sync foreground service. When the user saves or syncs articles, the app downloads their text and images so they can be read offline. For large batches, and while importing a list of links from another app, the work can take longer than a few minutes and must continue if the user leaves the app, so it runs as a user-visible foreground service with a progress notification (via WorkManager). It is started only by user actions (saving, syncing, importing), stops when the download or import is complete, and does not run continuously.
```
Play may ask for a short screen recording: show saving several articles (or running an Import) with the progress notification, then the notification disappearing. Not recorded yet; the owner must do it.

### Notifications
`POST_NOTIFICATIONS` is only for the download/import progress notification. No marketing or promotional notifications. No Play declaration form, but mention it if asked.

### Not applicable
Exact alarms, full-screen intent, photo/video permissions, health permissions, `QUERY_ALL_PACKAGES`, `MANAGE_EXTERNAL_STORAGE`: not used.

## Release notes for 1.5.0 (versionCode 8), en-US (max 500 chars)
```
Swipe actions: choose what swiping a list item to the left or right does (Archive, Favorite, Tags or nothing) in Settings. A short peek on your first visit shows that rows can be swiped.
Plus small fixes and polish.
```
Count: about 190 (limit 500).
Note: only claims what commit 2ca4c74 ("swipe hint peek and configurable swipe actions") did. Add other items if the 1.5.0 changelog has them.
