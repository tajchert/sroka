# Sroka Android — binding decisions (A-rulings)

Authoritative for every agent working in `apps/android`. Overrides the template docs. Server contract: repo `docs/api.md`
(§2.1 auth, §4 objects, §5.7 content, §7 sync, §8 ops, §12 account/config, §13 URL normalization). Server decisions: `docs/decisions.md`.
If a ruling here turns out wrong, change it HERE first (one commit), then code.

## A1 Identity & toolchain
- Location `apps/android` (own Gradle root, not an npm workspace). Package/namespace root `app.sroka`; applicationId `app.sroka`, debug `app.sroka.debug`.
- Gradle needs JDK 21: `export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home`. Run `./gradlew` from `apps/android`.
- Template baseline kept: Kotlin 2.4.20, AGP 9.4.1, compose BOM 2026.09.00, Navigation 3 1.2.0, Hilt 2.60.1, Room 3.0.3 (`androidx.room3`), DataStore 1.2.1, minSdk 26, target/compile 37.
- Added (stable only; check `https://dl.google.com/android/maven2/<group path>/group-index.xml` or Maven Central metadata for the latest stable):
  `androidx.room3:room3-paging` (= room version), `androidx.paging:paging-compose` 3.5.x, `androidx.work:work-runtime-ktx` 2.11.x, `androidx.hilt:hilt-work` + `androidx.hilt:hilt-compiler` (ksp),
  `androidx.webkit:webkit` (WebViewAssetLoader), `androidx.browser:browser` (Custom Tabs), `com.squareup.okhttp3:okhttp` 5.x (+ `mockwebserver3` for tests),
  `io.coil-kt.coil3:coil-compose` 3.x (local thumbnail files only), `androidx.lifecycle:lifecycle-process` (foreground sync trigger).
  No Retrofit: a small hand-written OkHttp + kotlinx.serialization client (A5).
- Removed from template: Tasks feature + sample host + demo seed + task benchmarks/screenshot refs, App Link intent filters for `sroka.app` (no assetlinks yet).

## A2 Modules (template layering kept)
```
app                       MainActivity, ShareActivity, SrokaApplication (Hilt + WorkManager Configuration.Provider), nav host, top-level scaffold
feature/auth/{api,impl}   sign-in (email → 6-digit code)
feature/library/{api,impl} My List / Archive / Favorites / Tags tabs, search, add-URL, fetch button + progress, item actions
feature/reader/{api,impl} WebView reader of offline content
feature/settings/{api,impl} downloads policy, storage, theme/reader text, server URL, account
core/model                pure Kotlin models (A3) + uuidv7 + UrlNormalizer (port of api.md §13, tests mirror packages/shared/src/url.test.ts)
core/common               dispatchers, ApplicationScope, Clock
core/designsystem         theme (Material 3, dynamic color, brand fallback: black/white + teal accent #1F8A84)
core/ui                   ItemRow, ItemThumbnail, OfflineBadge, TagChips, EmptyState, common strings
core/database             Room DB `SrokaDatabase` (A4)
core/datastore            prefs (A6), SessionStore (token, Keystore-encrypted), deviceId
core/network              SrokaApi (A5)
core/domain               INTERFACES consumed by features (`app.sroka.core.domain`): LibraryRepository, TagRepository, SyncController, SyncStatusRepository, ContentStore (reader-facing part), AuthRepository, SettingsRepository, AccountRepository
core/data                 implementations of core:domain interfaces + SyncEngine + workers (A7–A9), Hilt @Binds
core/testing              fakes of every core:domain interface, test data builders, MainDispatcherRule
```
Features depend on `core:domain` + `core:ui` + `core:designsystem` + `core:model` (+ `core:common`) only; never on core:data/database/network/datastore — so features compile while core:data is being built. Only `app` depends on `core:data`. Each feature impl exposes `fun EntryProviderScope<NavKey>.<feature>Entries(navigator…)` (template pattern) wired in `app`.

## A3 Models (`core:model`, package `app.sroka.core.model`)
- `Item(id, url, canonicalUrl, title: String?, excerpt, siteName, author, lang, leadImageKey, wordCount: Int?, readingMinutes: Int?, contentId: String?, contentPrivate, parseStatus: ParseStatus, parseError: String?, status: ItemStatus, isFavorite, progress: Float, progressAnchor: Int?, savedAt: Long, archivedAt: Long?, lastReadAt: Long?, source: String?, tags: List<String>, offline: OfflineState, thumbnailPath: String?)`
  `displayTitle` = title ?: domain; `domain` = host without `www.`.
- `ItemSummary` (list row projection): id, displayTitle, domain, excerpt, readingMinutes, status, isFavorite, progress, parseStatus, offline, thumbnailPath, tags, savedAt.
- enums: `ItemStatus {UNREAD, ARCHIVED}`, `ParseStatus {PENDING, OK, PARTIAL, FAILED}`, `OfflineState {NONE (no content on server yet), AVAILABLE_REMOTE, QUEUED, DOWNLOADING, DOWNLOADED, FAILED}`,
  `LibraryTab {MY_LIST, ARCHIVE, FAVORITES}`, `SortOrder {NEWEST, OLDEST, SHORTEST, LONGEST}`, `DownloadPolicy {WIFI_ONLY (default), ANY_NETWORK, MANUAL}`, `ThemeMode {SYSTEM, LIGHT, DARK}`, `ReaderTheme {AUTO, LIGHT, SEPIA, DARK}`.
- `ItemQuery(tab: LibraryTab, tag: String? = null, search: String? = null, sort: SortOrder = NEWEST)`; when `tag != null` the tab filter is ignored except ARCHIVE vs not? → No: tag view shows all live items with that tag (any status).
- `TagCount(name, count)`.
- `SyncStatus` (A9). `SessionState {SignedOut, SignedIn(email), Expired(email)}` (Expired = server returned 401; local data kept, banner asks to sign in again).
- `newUuidV7(clock)`; `UrlNormalizer.normalize(url): String?` (null = invalid) and `extractFirstUrl(text): String?` (share text "Title https://…").

## A4 Database (`core:database`, Room 3, file `sroka.db`, version 1, `exportSchema = true` → `core/database/schemas/`)
Never destructive migrations. Every future change = new version + `Migration` + migration test. Tables:
- `items` — one row per live item (server tombstone ⇒ row deleted). Columns mirror Item wire fields in snake_case + local columns:
  `id TEXT PK, url, canonical_url, title, excerpt, site_name, author, lang, lead_image_key, word_count, reading_minutes, content_id, content_private INT, parse_status TEXT, parse_error, status TEXT, is_favorite INT, progress REAL, progress_anchor INT, saved_at INT, archived_at INT, last_read_at INT, source, server_seq INT (null = never seen from server), fts_rowid INTEGER NOT NULL UNIQUE, resync_mark INT NOT NULL DEFAULT 0`.
  Indexes: `(status, saved_at)`, `(is_favorite, saved_at)`, `(status, word_count)`, `canonical_url`, `fts_rowid` unique.
  `fts_rowid` allocated on insert as `COALESCE(MAX(fts_rowid),0)+1` inside the insert transaction (stable; never reused for another item while the row lives).
- `item_tags(item_id, name_key, name, PK(item_id, name_key))`, index `(name_key)`; FK to items ON DELETE CASCADE. `name_key` = NFC-trimmed-collapsed name `.lowercase(Locale.ROOT)` (Kotlin `tagKey`, port of shared `tagKey`).
- `tags(id TEXT PK, name, name_key UNIQUE)` — server tag rows from pull (for empty tags + ids); tag list = union with `item_tags` counts.
- `items_fts` — `@Fts4(tokenizer = UNICODE61, tokenizerArgs = ["remove_diacritics=2"])` columns `title, excerpt, site_name, tags, body`; rowid = `items.fts_rowid`. Maintained by DAO code in the same transaction as the item change (insert/update/delete). `body` = plain text of the downloaded article (empty until downloaded). Query: each user term → `"term"*` (strip FTS syntax chars `" * ( ) : ^ -` etc.), AND-ed; join `items ON items.fts_rowid = items_fts.rowid`.
- `pending_ops(local_seq INTEGER PK AUTOINCREMENT, op_id TEXT UNIQUE, item_id TEXT, type TEXT, payload TEXT /* full wire JSON of the op */, created_at INT, attempts INT DEFAULT 0, last_error TEXT)`, index `item_id`.
- `sync_state` single row `(id=1, cursor INT, last_success_at INT, last_error TEXT, full_resync INT)`.
- `content_files(item_id PK FK→items CASCADE, content_id, state TEXT /*QUEUED|DOWNLOADING|DOWNLOADED|FAILED*/, bytes INT, attempts INT, error TEXT, downloaded_at INT, thumb_path TEXT)`. `OfflineState` derives: no content_id on item → NONE; no row or row.content_id ≠ item.content_id → AVAILABLE_REMOTE; else row.state.
- List queries return `PagingSource<Int, ItemSummaryRow>` (room3-paging) with a lightweight projection (no excerpt beyond 200 chars? → excerpt not in row projection; tags via `group_concat` subquery). Count queries for badges/progress are `Flow`.
Files on disk (not in DB): `filesDir/articles/{itemId}/` (unzipped package: `article.html`, `img/…`, `manifest.json`), `filesDir/thumbs/{itemId}.webp`.

## A5 Network (`core:network`, OkHttp 5 + kotlinx.serialization, `Json { ignoreUnknownKeys = true; explicitNulls = false }`)
- Base URL from settings (A6): release default `https://api.sroka.app`, debug default `http://localhost:8787` (use `adb reverse tcp:8787 tcp:8787`; dev CONTENT_ORIGIN `http://127.0.0.1:8787` then also resolves). Debug-only network security config allows cleartext for `localhost`, `127.0.0.1`, `10.0.2.2`.
- Headers: `Authorization: Bearer <token>` (verbatim `set-auth-token` value), `X-Sroka-Device: <deviceId>`, `User-Agent: Sroka-Android/<versionName>`.
- `interface SrokaApi` (suspend, returns `ApiResult<T>` = `Success(T) | HttpError(status, code: String?, retryAfterSec: Long?) | NetworkError(IOException)`; never throws except CancellationException):
  `sendOtp(email)`, `signIn(email, otp): SignInResult(token, userEmail)` (token from header `set-auth-token`; Better Auth errors body `{code,message}`: INVALID_OTP, OTP_EXPIRED, TOO_MANY_ATTEMPTS; 429 `X-Retry-After`), `signOut()`,
  `push(deviceId, ops: List<JsonObject>): PushResponseDto`, `pull(cursor, limit=500): PullResponseDto` (410 → HttpError code `resync_required`),
  `contentUrls(itemId): ContentUrlsDto` (409 `not_parsed`), `download(url, dest: File, onProgress)` (streams to a file, unauthenticated — signed URL), `me()`, `config()`, `deleteAccount()` (`{"confirm":"DELETE"}`), `getItem(itemId)`.
- DTOs exactly per api.md §4.1/§7 (`ItemDto` all fields nullable-safe, `leadImageUrl`, `leadImageKey`, `seq`).
- Errors `/v1`: `{error, message?}`; 429 `Retry-After`.

## A6 Preferences & session (`core:datastore`)
- `UserPreferences(themeMode, dynamicColor=true, downloadPolicy=WIFI_ONLY, readerTheme=AUTO, readerTextScale=1.0f (0.8..1.6), sortOrder=NEWEST, serverUrl: String?)` via Preferences DataStore, forward-compatible enum decoding (template pattern).
- `SessionStore`: token encrypted with an AES-GCM key in AndroidKeyStore, ciphertext in a separate DataStore file `session.preferences_pb`; also signed-in email, `expired` flag. Excluded from backup (`data_extraction_rules`/`backup_rules` exclude both DataStore files and `sroka.db`? → **exclude session file only**; DB may back up but token never). Key loss (restore on new device) ⇒ treat as signed out, keep DB.
- `deviceId`: generated once `"and_" + uuidv7`, stored in DataStore, never changes for the install.

## A7 Writes are local-first (`core:data` `LibraryRepository`)
Every user action = one Room transaction that (1) updates the local row(s) + FTS and (2) inserts the wire op into `pending_ops`; then `SyncScheduler.requestSync()` (debounced 2 s). UI never waits for network.
- `save(url, title?, tags, source="share"|"web")`: normalize (invalid → `SaveResult.InvalidUrl`); if a live local item has that canonical URL → re-add locally (status unread, savedAt=now, union tags) and push `item.add` with **that** itemId; else new item id `uuidv7`, parse_status pending, `item.add {onDuplicate:"readd", source, savedAt, title, tags}`. Returns `SaveResult.Saved(itemId, alreadySaved: Boolean)`.
- `setStatus`, `setFavorite`, `setProgress(progress, anchor)`, `setTitle`, `setTags(itemId, names)` (diff → `item.tag` ops), `delete` (local row + files removed; `item.delete`), `refresh` (`item.refresh`, local parse_status pending), `renameTag(from,to)` (local merge by name_key), `deleteTag(name)`.
- Op coalescing: inserting `item.setProgress` for an item deletes older un-sent `item.setProgress` ops of that item (same for `setStatus`, `setFavorite`, `setTitle`). Never coalesce `item.add`, `item.tag`, `item.delete`, tag ops.
- `at` = `System.currentTimeMillis()`; `opId` = uuidv7.

## A8 Sync engine (`SyncEngine.sync(): SyncOutcome`, run only from `SyncWorker`; a Mutex makes it single-flight)
1. **Push** pending ops in `local_seq` order, batches ≤ 500. Response: `applied` → delete those ops; `rejected` → delete op (reason `item_deleted` ⇒ delete local item + files; others logged); `aliases{client→existing}` ⇒ in one transaction rewrite `pending_ops.item_id` and payload `itemId` for client id, delete the local client row (keep local tags/progress by applying them as ops? → no: the server already merged tags from the add; just drop the row) and remember to re-pull. Network/5xx ⇒ stop, keep ops, `Result.retry()` with backoff. 401 ⇒ `SessionState.Expired`, stop, keep everything.
2. **Pull** from `sync_state.cursor` until `hasMore=false`; each page applied in **one transaction** together with the new cursor: upsert items (preserve `fts_rowid`, local `content_files`), replace `item_tags`, upsert/delete `tags`, delete `deleted.items` (+ their files after commit). Then **rebase**: for each item touched in the page that has pending ops, re-apply those ops' local effect on top (so un-pushed local edits are not overwritten by older server state).
   If `content_id` changed for an item with a downloaded package ⇒ mark `content_files` stale (state AVAILABLE_REMOTE derivation handles it) — old files stay readable until the new package replaces them.
3. **410 resync_required** ⇒ push first, then set `resync_mark=1` on all items, pull from 0 (pulled rows reset mark to 0), afterwards delete items still marked that have no pending ops.
4. After a successful sync: enqueue `ContentDownloadWorker` per policy (A9) and run eviction (A9).
Triggers: app start/foreground (ProcessLifecycleOwner), after local writes (2 s debounce), pull-to-refresh / Fetch button, periodic `PeriodicWorkRequest` 1 h with `NetworkType.CONNECTED`. Unique work name `sroka-sync`, `ExistingWorkPolicy.APPEND_OR_REPLACE`, expedited (`OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST`).

## A9 Offline content (`ContentStore` + `ContentDownloadWorker`)
- Eligible = live items with `content_id != null` and (`status = UNREAD` or `is_favorite`) whose `content_files` is missing/stale/FAILED(attempts < 5). Order: newest `saved_at` first.
- Per item: `GET /v1/items/:id/content` → `packageUrl` → download to `cacheDir/dl/{itemId}.zip` → unzip **safely** (reject absolute paths / `..` / entries outside dir; caps: 50 MB total, 200 entries) into `filesDir/articles/{itemId}.tmp/` → verify each manifest `files[].sha256` → atomic rename to `articles/{itemId}/` (replace old) → extract body text from article.html (strip tags, decode entities; no Jsoup) → update FTS `body` + `content_files` DOWNLOADED. Thumbnail: if `lead_image_key`, download `baseUrl + leadImageKey` → `thumbs/{itemId}.webp` (failure non-fatal).
- 409 `not_parsed` ⇒ skip (row stays AVAILABLE_REMOTE/NONE). Other failure ⇒ FAILED with attempts++.
- Worker: unique `sroka-download`, `ExistingWorkPolicy.KEEP` for automatic, `REPLACE`-free `APPEND_OR_REPLACE` after a user "Fetch". Constraints: WIFI_ONLY → `UNMETERED`; ANY_NETWORK → `CONNECTED`; MANUAL → not auto-enqueued. **User-initiated "Fetch new articles" ignores WIFI_ONLY** (explicit action) and runs `sync → download` as one `WorkContinuation`. Foreground: `setForeground` with a low-importance progress notification channel `downloads` ("Downloading articles 3/12"), `foregroundServiceType="dataSync"`; POST_NOTIFICATIONS requested lazily on first Fetch (denial must not block downloads). `setProgress(workDataOf("done","total","title"))` after each item. Concurrency: 3 parallel downloads.
- Eviction after sync: delete packages of archived non-favorite items archived > 30 days ago; storage usage = sum `content_files.bytes` + thumbs. "Remove downloads" in settings clears all packages (rows → AVAILABLE_REMOTE).
- `SyncStatusRepository.status: Flow<SyncStatus>` combining WorkInfo flows of both unique works + Room counts:
  `SyncStatus(phase: Idle|Syncing|Downloading(done,total,currentTitle)|Offline|Error(kind: AUTH|NETWORK|SERVER), pendingOps: Int, downloadedCount: Int, availableCount: Int, lastSyncAt: Long?)`.

## A10 Reader
- WebView in Compose (`AndroidView`), content served via `WebViewAssetLoader` path handler `https://appassets.androidplatform.net/articles/` → `filesDir/articles/` (no `file://`, `allowFileAccess=false`, `allowContentAccess=false`, `blockNetworkLoads=true` for the article document; `javaScriptEnabled=true` only for the app reader script). Link taps → Custom Tabs (http/https only), never navigate the WebView.
- App wraps `article.html` (read from disk, injected via `loadDataWithBaseURL("https://appassets.androidplatform.net/articles/{itemId}/", html…)`) with theme CSS (reader theme + text scale, system font, max-width 42em, readable line-height) and the reader script; progress messages via `WebViewCompat.addWebMessageListener` limited to origin `https://appassets.androidplatform.net` (fallback `addJavascriptInterface` if the feature is unsupported).
- Progress = scrollTop/(scrollHeight−clientHeight) clamped 0..1, anchor = index into `querySelectorAll("p,h1,h2,h3,h4,h5,h6,li,blockquote,pre,figure")` of the first element at/below the top (same as web). Saved locally (op coalesced) ≤ every 2 s while scrolling and on leave. Restore by anchor (fallback progress) after load.
- Not downloaded: if online and `contentId != null` ⇒ download this item now (`ContentStore.downloadNow(itemId)`) with a spinner; pending parse ⇒ "Still being prepared"; failed ⇒ parseError + "Open original" + "Try again" (refresh). Always offer "Open original".
- Top app bar: back, favorite, archive (archives and goes back with undo snackbar on the list), share (original URL), overflow: open original, edit tags, refresh article, text size/theme sheet, delete.

## A11 UX rules (native Android, simple; designer rework later)
- Material 3, dynamic color on 12+, edge-to-edge, predictive back, `NavigationSuiteScaffold` (bottom bar phone / rail tablet) with **My List · Archive · Favorites · Tags**; settings via top-bar action. Navigation 3 back stack (template).
- Library top bar: title, search action (M3 `SearchBar` expanding, results from local FTS, works offline), sort menu, **"Fetch new articles" action (CloudDownload icon) — also pull-to-refresh**. Progress: a `LinearProgressIndicator` under the top bar + a one-line status row ("Syncing…", "Downloading 3 of 12", "Offline · showing saved articles", "Sign in again to sync"). Completion snackbar ("12 articles ready offline" / "Library is up to date").
- Rows: title (2 lines), `domain · N min`, tag chips (max 2), thumbnail 72dp right (local file), offline-downloaded icon, unread progress bar thin at bottom if 0<progress<1. Swipe end→start = archive (in Archive tab: move to My List), start→end = favorite; undo snackbar. Long-press → bottom sheet actions.
- FAB "Add" (extended on empty list) → dialog with URL field prefilled from clipboard if it holds a URL.
- Empty states per tab with one-line guidance ("Share any link to Sroka to save it").
- Share target: `ShareActivity` (translucent, `excludeFromRecents`), `ACTION_SEND text/plain`; saves locally and shows a small Compose bottom sheet "Saved to Sroka ✓" with "Add tags" and auto-dismiss after ~2.5 s; not signed in ⇒ message + "Sign in" opens MainActivity. Works offline.
- All user-facing strings in `strings.xml`; content descriptions on icon buttons; touch targets ≥48dp.

## A12 Testing & verification (per module, keep output short)
- Unit tests (JVM/Robolectric) for: UrlNormalizer (port shared url.test.ts cases), uuidv7, tagKey, op building + coalescing, SyncEngine (push/aliases/rejects/rebase/410) against MockWebServer + in-memory Room, ContentStore unzip safety + sha verify, DAO queries (Robolectric in-memory Room), ViewModels with fakes.
- Commands: `./gradlew :core:data:testDebugUnitTest` etc. Full gate before merge: `./gradlew testDebugUnitTest lintDebug assembleDebug :app:assembleRelease`.
- Commit per agent task with conventional messages scoped `android` (e.g. `feat(android): sync engine`), only your own paths (`git add <paths>`; retry if `index.lock` exists).
