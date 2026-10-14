# Sroka for Android

Native Android client for **Sroka**, the read-later app (Pocket successor). Save links from any app through the share
sheet, read them later, **fully offline**, in a clean reader. Kotlin, Jetpack Compose, Material 3, Room, WorkManager.

- **Save**: share any link to Sroka, or tap *Add*. The save works offline and syncs later.
- **Library**: My List · Archive · Favorites · Tags, with local full-text search, sorting, swipe to archive or favorite.
- **Fetch new articles**: one button (or pull to refresh) syncs with the server and downloads every new article
  for offline reading, with visible progress ("Downloading 3 of 12").
- **Reader**: the offline article package rendered in a sandboxed WebView, with the reading position synced across devices.

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

JDK 21 and the Android SDK are required. The exact commands (single-module tests, full gate, local backend with
`adb reverse`) are in [`CLAUDE.md`](CLAUDE.md#commands-run-in-appsandroid).

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
./gradlew testDebugUnitTest assembleDebug     # tests + debug APK
./gradlew :app:installDebug                   # install on a running emulator/device
```

Debug builds talk to `http://localhost:8787` (the local `wrangler dev` stack) and release builds to
`https://api.sroka.app`. You can change the server in Settings.

## Docs

- [`docs/DECISIONS.md`](docs/DECISIONS.md): binding Android rulings (A1–A12)
- [`docs/LEDGER.md`](docs/LEDGER.md): build progress
- Template guides inherited from the starter (testing layers, screenshots, releasing, performance) are in [`docs/`](docs/).
