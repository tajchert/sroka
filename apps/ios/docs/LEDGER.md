# iOS build ledger

Integration branch: `t3/ios-app-native`. Brief: `apps/ios/docs/BRIEF.md`.

## Wave 0 (2026-11-20)

- Xcode 27.2, iOS 27.2 simulator runtime, `xcrun swift-format` 6.4.4: OK.
- Template `verify.sh format` and `build Dev` pass on this machine (needs `SIM_OS=27.2`; the template defaults to 27.0).
- Local stack inputs (`.dev.vars`, `node_modules`) are missing in this worktree; needed only for journeys in wave 3 (`npm install`, `npm run dev:setup`).

## Streams

| Stream | Scope | Model | Status | SHA |
|---|---|---|---|---|
| F | Foundation | Opus | merged | 3fa36fe |
| A | Core logic + network | Sonnet | merged | 17ecc0f |
| B | Database | Opus | merged | 13acf50 |
| C | Library UI | Sonnet | merged | 6e5be88 |
| D | Reader UI | Sonnet | merged | 4306803 |
| E | Auth + settings UI | Sonnet | merged | 0b26f9b |
| G | Sync | Opus | merged, Sol approved | e12c538 |
| H | Content | Opus | merged, Sol nits declined | 7be6b6a |
| I | Session | Opus | merged, Sol reviewed | b05c56b |
| J | Tags + search UI | Sonnet | merged | 1dcc69a |
| K | Share extension (K1 sheet, K2 live) | Opus | merged; final-review fixes S1-S3 | d95403b, eb7e4bd, 87cda1b |
| L | App composition (L1 live graph, L2 navigation) | Opus | merged; final-review fixes S4-S7 | 811ca9a, ea87cdf, 85edefc |
| P | UI fix rounds (P1, P2), flaky test (R) | Sonnet | merged | 1c0feae, 41531a5, a4d9cdb |
| Q | Journeys a-h against the local stack (`scripts/journey.sh`) | Sonnet | merged; reader follow-up running | ea5995a, 5f7de50, b4770c0 |
| Z | Final Sol review | Sol | 5 rounds; APPROVE on 44f4470 |  |
| M | Firebase telemetry + release preflight | Sonnet | merged (no archive/export run; Release path not in verify.sh) | 58c60d8 |

## Open items

- Stream L: `HTTPSrokaAPI` takes base URL and token from one snapshot.
- Polish: feature String Catalogs are empty; check reader glass and insets on a simulator.
- Final review: untested race fixes in H (4) and G (2).
- Gate on ad8eb4d (after D, J): format and `build Dev` pass; full `unit` had one failure, `LibraryViewModelTests` "Filters combine with AND", which passed 3 of 3 alone. Flaky under the parallel run; fix in polish.

- L1 open risks: a late 401 can sign out a new account; no local notification when an import ends; background tasks and Keychain access group untested on a device.
- K2 must know: Keychain service `app.sroka.session`, session JSON has `server`, op clock key `sroka.opClock.last` in App Group defaults, extension `OpWriter` has no write gate.
- After L2: zoom transition not done; app-target strings are literals; archive-and-next, delete in reader, sign-out not exercised on a simulator.

- Gate on 5b6e921 (L1 + L2 joined): format, `build Dev`, `build Prod` pass; full `unit` fails on two tests that pass alone: `LibraryViewModelTests` "Filters combine with AND" (P1) and `AppModelTests` "The root follows the session and the version gate" (R).

- After K2: an unknown `sroka://item/{id}` should open the library; `clearTables` must stay safe to run twice; a PDF can upload twice if the extension is killed mid-upload (declined S8).
- Device-only checks: opening the app from the extension, extension memory limit, writes drained before suspend (0xdead10cc), Keychain access group on a signed build, background tasks.

- Gate on 0d67a1d (after K2): format, full `unit`, `build Dev` all pass. Not rerun after P2.
- Final review round 1 (on be1ec6a): S1 PDF upload owner/credentials, S2 double upload across processes, S3 extension writes during a wipe (87cda1b); S4 reauth resumes uploads and import, S5 late delete-account, S6 background expiry, S7 account switch (85edefc). S8 (late 401 signs out a new account) declined: needs an `ApiError`/`SyncSession` protocol change across 8 call sites; open risk.
- Rounds 2-5 fixes: 2349ca6, 5a5e9ff, 15d53c9, d6b2f35, d8b9426, 44f4470. Declined nits: S8 (above), S14 (parse poll 5-minute limit counts only sleeps), S15 (sync observer task has no owner), S16 (OTP sign-in can succeed while the install check is unresolved; sync starts at the next reload).
- Journey findings fixed: parse polling while active (`ParsePoller`: 2, 4, 8, 16 s, then 30 s, gives up after 5 min), first-run Keychain clear (`InstallCheck`), resume notice after the page is displayed.
- Gate on b4770c0 (after Sol approval and journeys): format, full `unit`, `build Dev`, `build Prod` pass. Journeys a-h pass on the same code (8 tests).

## Open items for the owner

- `GoogleService-Info.plist` for the iOS app in Firebase project `sroka-95489` → `apps/ios/Config/GoogleService-Info.plist`.
- Apple team id → `apps/ios/Config/Local.xcconfig` (`DEVELOPMENT_TEAM = …`); App IDs `app.sroka`, `app.sroka.share`, App Group `group.app.sroka`.
- `REVIEW_EMAIL` / `REVIEW_OTP` Worker secrets before App Review.
