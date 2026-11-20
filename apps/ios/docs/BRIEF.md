# Sroka iOS — build brief (shared contract for all agents)

Native SwiftUI client with feature parity to Android 1.5.0. No backend changes.
Read only the sections your task names. If this brief and the code disagree, tell the orchestrator in your report; do not silently pick.

## Sources

| What | Where |
|---|---|
| Build plan + UI design (HTML, read by line range) | `apps/ios/docs/plan/sroka-ios-plan.html` |
| Template the app is copied from (best-practice sample) | `/Users/mtajchert/coding/priv/ai-ios-template` (`AGENTS.md`, `ARCHITECTURE.md`) |
| HTTP + sync contract | `docs/api.md`; rulings `docs/decisions.md` |
| Android reference | `apps/android` (`…` in the plan = `src/main/kotlin/app/sroka/<module path>`) |
| Logic source of truth + vectors | `packages/shared/src/*.ts`, `*.test.ts` |

Plan line ranges in `sroka-ios-plan.html`: scope/parity 346–371 · server contract 372–426 · architecture 427–466 · database 467–488 · sync 489–515 · offline content 516–536 · reader 537–552 · share extension 553–570 · background work 571–585 · session/sign-out 586–598 · preferences 599–618 · telemetry/privacy 619–630 · logic ports 631–646 · testing 647–675 · risks 723–736.
UI design: principles 746–754 · screens (phone mock-ups with captions) 755–1070 · colour 1071–1076 · icon 1077–1090 · Android→iOS component map + SF Symbols 1091–1133 · type/shape/motion/accessibility 1134–1161 · Liquid Glass rules 1162–1174.

## Owner decisions (final)

- Minimum OS **iOS / iPadOS 27.0** (plan says 26; 27 wins). Use iOS 26/27 APIs directly, no availability fallbacks. Xcode 27.2, Swift 6 language mode, strict concurrency.
- Telemetry: **Firebase Analytics + Crashlytics**, existing project `sroka-95489`; the owner will add the iOS app and supply `GoogleService-Info.plist` (gitignored, at `apps/ios/Config/GoogleService-Info.plist`). The build must work without it: no file or placeholder → no-op telemetry. Firebase is linked **only into the app target** (SPM dependency of the Xcode project, not of `Modules`), behind the `Telemetry` protocol. Debug builds send nothing.
- Navigation (I1): tab bar My List / Archive / Tags + search tab on iPhone; `NavigationSplitView` on iPad.
- Type (I4): San Francisco for UI, Outfit (bundle `apps/android/core/designsystem/src/main/res/font/outfit.ttf`) only for brand headings (sign-in, onboarding, empty-state titles).
- I5: no Mac/Vision work. I6: keep the "Save from Chrome" onboarding step.
- UI is native iOS (system components, Liquid Glass per the plan's rules), not a copy of the Android look. Words stay the same as Android/`vocab.ts`.

## Project shape

- Location `apps/ios` (own Xcode project, not an npm workspace). Project `Sroka.xcodeproj`, targets `Sroka` (app), `SrokaShare` (share extension, replaces the template's widget), `SrokaUITests`. Schemes `Sroka Dev`, `Sroka Prod`.
- Environments (template's xcconfig axis): Dev = bundle `app.sroka.dev`, group `group.app.sroka.dev`, default server `http://localhost:8787`; Prod = `app.sroka`, `group.app.sroka`, `https://api.sroka.app`. Share extension `<bundle>.share`. Shared Keychain access group for the token. URL scheme `sroka://item/{id}` (Dev: `sroka-dev://`).
- `DEVELOPMENT_TEAM` comes from an optional gitignored `apps/ios/Config/Local.xcconfig`; simulator builds need none.
- All code in one local package `apps/ios/Modules`. Third-party: swift-dependencies, swift-clocks, swift-snapshot-testing (from the template), GRDB, ZIPFoundation. Nothing else without asking.
- Template conventions apply unchanged (`apps/ios/AGENTS.md` after the foundation lands): `@Observable @MainActor` view models that do not import SwiftUI, `@Dependency` injection, no `Date()`/`UUID()`/`Task.sleep` in view models, one `View` type per screen section, size class decides layout, Swift Testing with sentence-case names, swift-format strict.

## Modules and ownership

Dependency direction is top to bottom; features never import each other or any live module.

| Module | Contents | Stream |
|---|---|---|
| `SrokaCore` | Models, domain protocols (repositories, `Telemetry`, stores) + dependency keys, limits, vocabulary. `Logic/`: `UrlNormalizer`, `UUIDv7`, tag normalisation, `OpClock`, wire op types | F (types, protocols) · A (`Logic/`) |
| `SrokaTesting` | In-memory fakes for every domain protocol, fixtures (sample items, tags) for previews, tests, snapshots | F |
| `SrokaDesign` | Colour assets, type, Outfit font, glass helpers, strings shared by features. `Components/`: item row, chips, toast, banners | F (tokens) · C (`Components/`) |
| `SrokaNetwork` | `URLSession` API client, DTOs, error model | A |
| `SrokaDatabase` | GRDB schema, migrations, FTS5, queries, observation, App Group setup | B |
| `SrokaSync` | `OpWriter`, `LocalOpApplier`, `SyncEngine` actor, sync status, live library/tag repositories | G |
| `SrokaContent` | Content store, package installer, eviction, PDF upload | H |
| `SrokaSession` | Keychain session store, preferences store, auth/account/settings/consent/data-transfer repositories, local wipe | I |
| `AuthFeature` | Email + code screens | E |
| `LibraryFeature` | My List / Archive list, filters, sort, swipe, context menu, continue reading, status cards, add link/PDF sheet, onboarding/empty states | C |
| `TagsFeature` | Tags screen, tag editor sheet | J |
| `SearchFeature` | Search tab | J |
| `ReaderFeature` | Web reader, appearance sheet, end-of-article card, reader states, PDF viewer | D |
| `SettingsFeature` | Settings form, import, export, consent prompt | E |
| `ShareFeature` | Save sheet UI + view model used by the extension | K |
| App target | Composition root, root navigation, deep links, background tasks, Firebase telemetry, version gate | L |

Cross-feature presentation (e.g. the list asking for the tag editor or the reader) goes through the feature's navigation intent/closure handled by the app root, never by importing another feature.

Each stream edits only its modules (Sources + matching Tests) plus its own lines in `Modules/Package.swift`. If you need a change in a module you do not own, make the smallest change, and list it in your report.

## Rules that bite (from the plan; do not rediscover)

- Never send an `Origin` header; all API traffic through the one `URLSession` client. Token arrives in the `set-auth-token` response header, stored verbatim.
- `401` = session expired, keep data. Two error shapes (`{error,message?}` and `{code,message}`), two retry headers (`Retry-After`, `X-Retry-After`).
- Decode enum-like fields as strings with an unknown fallback; ignore unknown keys; omit nil fields when encoding.
- Hand-written URL normaliser (Foundation's `URL` differs from WHATWG). Port the test vectors first.
- Android docs have drifted; the Kotlin code wins (schema v3, 4 s save-sheet timeout, the preference table in the plan).
- Op payload JSON must be canonical (fixed encoder config or columns); no string replacement inside payloads.
- Item ids become file names and URLs: validate `^[A-Za-z0-9_-]{1,64}$`.
- Telemetry (D15): enum-only parameters; never URLs, titles, tags, emails, search text.
- Logging: no secrets, emails or article content in logs.

## Working rules for agents

- You work in your own git worktree. One plain command per Bash call, using absolute paths and `git -C <worktree> …`. No `cd … &&`, pipes, heredocs, `sed -i`, or `git stash`. Edit with Edit/Write; search with `grep`/`rg`.
- Simulator: create your own, do not use shared ones: `xcrun simctl create sroka-<stream> "iPhone 18 Pro"` and pass `SIM_NAME=sroka-<stream> SIM_OS=27.2` to `scripts/verify.sh`. Delete it when done (`xcrun simctl delete sroka-<stream>`). Never shut down or erase simulators you did not create.
- Build and test narrowly: `apps/ios/scripts/verify.sh unit <YourTestTargets>`; `build Dev` once before handoff. Long runs (over ~2 min) go in the background.
- Acceptance bar: `verify.sh format` clean; your unit targets pass; `verify.sh build Dev` passes; work committed (conventional commits, no push).
- Do not read images unless your task is a visual check. Do not start subagents unless your task says so.
- Stay within about 100 turns. If you run out, commit what works and report what is left.
- Final report, 15 lines or fewer: real branch (`git rev-parse --abbrev-ref HEAD`), SHA, what passed, what was not run, changes outside your modules, notes for the next wave.

## Waves

- **F** foundation: scaffold from the template, all module targets, `SrokaCore` types + protocols, `SrokaTesting` fakes, design tokens.
- **Wave 1** (parallel, on F): A core logic + network · B database · C library UI · D reader UI · E auth + settings UI.
- **Wave 2** (on A + B): G sync · H content · I session · J tags + search UI (after C).
- **Wave 3**: L app composition, background work, telemetry · K share extension · iPad and polish · journeys against the local stack · docs and release preflight.

Progress: `apps/ios/docs/LEDGER.md` (orchestrator only).

## Foundation notes (F landed at 3fa36fe)

- Domain protocols and dependency keys live in `SrokaCore`; previews and tests call `useFakes(Fakes())` from `SrokaTesting` (keys have no preview value and the test value reports an issue).
- `SrokaCore/Logic/` holds stubs `UrlNormalizer.hostOf(_:)`, `normalizeTagName`, `tagKey`; stream A replaces the bodies and keeps the signatures.
- Android's `SortOrder` is `LibrarySortOrder`. List paging is a growing limit: `observeItems(_:limit:)` returns `ItemPage` with `hasMore`.
- Every feature module has its own `Localizable.xcstrings`; placeholders are `<Name>PlaceholderView`, replace them.
- App and share extension still run on fakes (`App/AppComposition.swift` TODO, stream L). Info.plist does not yet allow http to localhost (stream A adds it).
- A changed domain protocol must be changed together with its fake in `SrokaTesting`; keep such changes minimal and list them in your report, because other streams compile against them.

## Wave 1 notes: A (core logic, network) and B (database) merged

- `SrokaCore/Logic`: `UrlNormalizer`, `UUIDv7`, `normalizeTagName`/`tagKey`, `OpClock` + `OpClockStore` (`save` is called under the clock's lock: keep it quick, no re-entry), `WireOp` (`payload`, `parse(payload:)`, `rewrite(payload:itemId:opId:)`).
- `SrokaNetwork`: protocol `SrokaAPI` (live `HTTPSrokaAPI`), `ApiSessionProvider` and `ClientIdentity` (implemented by stream I), `ApiError` (`remoteFailure`, `retryAfter`, `isResyncRequired`, `isNotParsed`, `isUnauthorized`, `pdfUploadError`), DTOs. An empty `push` is sent to the server, so do not call it with no ops; more than 500 is refused client-side. `download` has no auth header.
- `SrokaDatabase`: `AppDatabase` (`openShared(at:)`, `openForExtension(at:)`, `inMemory()`, `read`, `write`, `suspend/resume`, `notifyExternalChanges()`, `observe…` streams), DAOs `ItemDao`, `SearchDao`, `TagDao`, `PendingOpDao`, `SyncStateDao`, `ContentFileDao`, `MaintenanceDao.wipeAll`; DAO writes take a GRDB `Database` so several combine in one transaction.
- Database facts: re-keying an item deletes its `content_files` row (queue the download again); `PendingOpDao.retargetItem` takes a payload-rewriting closure (use `WireOp.rewrite`); `thumb_path` is stored as given and mapped with a `thumbnailBase`; the app must call `notifyExternalChanges()` on activation.
- `Share/Info.plist` has no ATS local-networking entry yet (stream K).

## Wave 2 notes: C, E, H, I merged (G sync, D reader, J tags + search still running)

- UI intents for the app root: `LibraryIntent` (`openItem`, `editTags`, `openSettings`, `signInAgain`, `openURL`), `AuthIntent`, `SettingsIntent`. Snapshot suites set `usesFlatControls` because tinted glass renders blank in `layer.render`.
- `SrokaContent`: `LiveContentStore` (`fetch`, `downloadNow`, `runAutomaticDownloads(policy:progress:)`, `downloadAll`, `evict`, `recoverInterrupted`, `deleteFiles(itemIds:)`, `clearDownloads`, `removeAllContent`, `makeWifiOnlySession`), `LivePdfUploader` (`enqueue`, `cancel`, `resumePendingUploads`, `cancelAll`), `ContentPaths.appGroup`. Layout under the App Group `Content/`: `articles/{id}/`, `thumbs/{id}.webp`, `downloads/`, `pdf-uploads/`. Pass `ContentPaths.root` as the database thumbnail base. Call `recoverInterrupted` and `resumePendingUploads` at launch, `evict` after each successful sync; on sign-out `cancelAll` then `removeAllContent`; `onUnauthorized` goes to the session.
- `SrokaSession`: construct `KeychainSecureStore`, `SessionStore`, `PreferencesStore(appGroup:)`, `LiveApiSessionProvider`, `ImportJobStore`, `ImportTracker`, `LiveDataTransferRepository`, `LocalDataWiper` (closures `cancelAllWork`, `clearTables`, `deleteFiles`, `transferDirectories`), `LiveAuthRepository` (`hasLocalData`, `requestSync`, `markSessionExpired()` for 401s from sync, content and upload), `LiveSettingsRepository` (`onDownloadPolicyChanged`), `LiveAccountRepository`, `LiveConsentRepository`, `ConsentGatedTelemetry`, `ConsentApplier.start()`, decorators `TelemetryLibraryRepository`, `TelemetryPdfUploader`, `TelemetryDataTransferRepository`. Call `reload()` on both stores when the app becomes active. A token is sent only when the stored account server matches the current server.
- Open fix (stream L): `HTTPSrokaAPI` reads base URL and token separately; it must take both from one snapshot so a server switch can never pair one server's URL with another's token.
- Open (polish): feature String Catalogs are empty (English key text is used).

## Wave 2 notes: G (sync) merged

- Entry points in `SrokaSync`: `SyncScheduler` (`requestSync`, `fetchNewArticles`, `downloadItemNow`, `syncNow`, `handleBackgroundRefresh`, `wipe`, `events`, `observeRunning`), `LiveLibraryRepository`, `LiveTagRepository`, `LiveSyncStatusRepository`, `PathNetworkStatus`, `OpWriter`, `SyncEngine.pushOnce` (share extension), `systemNowMillis`.
- Ports the composition root supplies: `SyncSession` (from `SrokaSession`), `SyncContentHooks` (from `SrokaContent`; `NoContentHooks` is the default), `OpClockStore`.
- A push op gets 6 attempts in total. `pushOnce` does not update `sync_state`. Search rows carry no thumbnail base.
- Two scheduler race fixes from review have no test; the final review looks at them.

## Wave 2 notes: D (reader) and J (tags, search) merged

- Reader entry point: `ReaderView(itemId:onIntent:)`. `ReaderIntent`: `close`, `editTags(itemId:)`, `openItem(String)`, `archived(itemId:)`, `archivedAndOpenNext(archivedId:nextId:)`, `deleted(itemId:)`.
- The reader serves packages itself from `sroka-article://{itemId}/` (`ArticleScheme.name`), reading `ContentStore.articlesDirectory()/{itemId}/`. This is the scheme that stays: each article gets its own origin. `ContentStoreURL` (`sroka-content`) in `SrokaCore` is unused; remove it in polish.
- From the content store the reader calls `articleHtml`, `downloadNow`, `observeOffline`, `pdfFile`, `ensurePdfFile`.
- Tags and search entry points: `TagsView`, `TagItemsView`, `TagEditorSheet`, `SearchView`, with `TagsIntent` and the search intent type in their modules.
- Glass surfaces (reader bottom bar, end card) render blank in snapshots; check them on a simulator. `window.innerHeight` with iOS insets in the reader script is unverified.
