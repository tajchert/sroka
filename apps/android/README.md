# Sroka for Android

Native Android client for **Sroka**, the read-later app (Pocket successor). Save links from any app through the share
sheet, read them later, **fully offline**, in a clean reader. Kotlin, Jetpack Compose, Material 3, Room, WorkManager.

## Features

- **Sign in** with an email code (6 digits, autofill/paste, auto-submit, resend cooldown). The session token is
  encrypted with an AndroidKeyStore key and never backed up. An expired session keeps the library usable and shows a
  "Sign in again" banner.
- **Save**: share any link to Sroka from another app (translucent "Save to Sroka" sheet with title and tag
  suggestions), or tap *Add* (clipboard prefill). Saving works offline and syncs later; re-saving a URL moves it back
  to My List.
- **Library**: My List · Archive · Favorites · Tags (bottom bar on phones, rail on larger windows). Paged lists with
  thumbnails and offline badges, swipe to archive or favorite (with undo), long-press actions (favorite, archive,
  edit tags, share, open original, refresh, delete), four sort orders, local full-text search over title, excerpt,
  site, tags and downloaded article text. Tags tab with counts, rename and delete.
- **Fetch new articles**: one button in the top bar (or pull to refresh) syncs and downloads every new article for
  offline reading, with progress under the top bar ("Downloading 3 of 12"), a progress notification and a result
  snackbar. Background sync runs on app start/foreground, after edits and hourly.
- **Reader**: the offline article package in a locked-down WebView (local assets only, no network, no JS from the
  article), themes Light/Sepia/Dark/Auto, text size, reading progress saved and synced, favorite/archive (with
  undo)/share/tags/delete. On tablets and unfolded foldables the reader opens next to the list.
- **Settings**: download policy (Wi-Fi only / any network / manual), *Download all now*, storage used, remove
  downloads, app theme and dynamic color, reader theme and text size, account (sign out wipes local data; delete
  account), Import/Export (opens the web app), server URL.

The product and server design live in the monorepo: [`docs/sroka-system-design.md`](../../docs/sroka-system-design.md),
HTTP/sync contract [`docs/api.md`](../../docs/api.md). Android rulings are in [`docs/DECISIONS.md`](docs/DECISIONS.md),
which overrides anything else here.

## Architecture

```
                              ┌──────────────────────────── app ────────────────────────────┐
                              │ MainActivity · ShareActivity · SrokaApplication (Hilt, WM)   │
                              │ Navigation 3 back stack + NavigationSuiteScaffold (tabs)     │
                              └───────┬──────────────────────────────────────────┬──────────┘
                                      │ entries + nav callbacks                  │ @Binds
         ┌────────────────┬───────────┴────┬────────────────┐                    │
   feature:auth     feature:library   feature:reader   feature:settings          │
   (api = NavKeys, impl = screens + ViewModels)                                  │
         └────────────────┴───────┬────────┴────────────────┘                    │
                                  ▼                                              ▼
            core:domain (interfaces) ◄──────────────────────────────── core:data (implementations,
            core:ui · core:designsystem · core:model · core:common          SyncEngine, ContentStore,
                                                                            workers)
                                                                     ┌─────────┼──────────┐
                                                               core:database core:network core:datastore
                                                               (Room + FTS)  (OkHttp)     (prefs, session)
```

Features depend only on `core:domain` interfaces (plus model/ui/designsystem/common), never on the data layer, and
reach other features through navigation callbacks the app maps to keys. `core:testing` provides in-memory fakes of
every `core:domain` interface.

## Offline model (summary)

- **Room is the source of truth.** The UI reads only the local database. Every user action is one transaction that
  updates local rows and queues a sync op in `pending_ops`, so the app never waits for the network (A7).
- **Sync** (`SyncWorker`): push queued ops, then pull changes since the last cursor, page by page, each page
  applied atomically and rebased under unsent local edits. It runs on app start, after edits, on *Fetch* and
  hourly (A8).
- **Article packages** (`ContentDownloadWorker`): zipped HTML and images, unpacked safely into
  `filesDir/articles/{itemId}/`, checksum-verified, and indexed into full-text search. Downloads run on Wi-Fi by
  default; *Fetch new articles* uses any network (A9).
- **Schema evolution**: Room schemas are exported; every change is a new version with a `Migration` and a migration
  test, never destructive (A4).

## Build & run

JDK 21 and the Android SDK (platform 37) are required. Run everything from `apps/android`:

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
./gradlew testDebugUnitTest lintDebug assembleDebug :app:assembleRelease   # full gate
./gradlew :core:data:testDebugUnitTest                                      # one module
./gradlew :app:installDebug                                                 # install on emulator/device
```

Debug builds (`app.sroka.debug`) talk to `http://localhost:8787` (cleartext allowed for localhost, 127.0.0.1 and
10.0.2.2 in debug only); release builds to `https://api.sroka.app`. The server can be changed on the sign-in screen
and in Settings.

### Against the local backend

```bash
# repo root, once: npm install && npm run dev:setup
npm run dev -w @sroka/api                 # wrangler dev on :8787 (api + parser)
adb reverse tcp:8787 tcp:8787             # device/emulator localhost:8787 -> your machine
```

Sign in with any email; the one-time code is printed in the wrangler log (`[sroka] OTP for …`). Save a link via
the share sheet or *Add*, then tap *Fetch new articles* to sync and download it for offline reading.

## Docs

- [`docs/DECISIONS.md`](docs/DECISIONS.md): binding Android rulings (A1–A12)
- [`docs/LEDGER.md`](docs/LEDGER.md): build progress
- [`CLAUDE.md`](CLAUDE.md): commands, layout and conventions for contributors and agents
- Template guides inherited from the starter: [testing](docs/TESTING.md), [screenshots](docs/SCREENSHOT_TESTING.md), [releasing](docs/RELEASING.md), [security defaults](docs/SECURITY_DEFAULTS.md), [localization](docs/LOCALIZATION.md), [performance](docs/PERFORMANCE_TESTING.md)

## Known gaps

- Launcher icon, notification icon and visual design are placeholders until the designer rework.
- English only.
