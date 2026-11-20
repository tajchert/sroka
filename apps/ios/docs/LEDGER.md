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
| D | Reader UI | Sonnet | running |  |
| E | Auth + settings UI | Sonnet | merged | 0b26f9b |
| G | Sync | Opus | merged, Sol approved | e12c538 |
| H | Content | Opus | merged, Sol nits declined | 7be6b6a |
| I | Session | Opus | merged, Sol reviewed | b05c56b |
| J | Tags + search UI | Sonnet | running |  |
| K | Share extension | Opus | running (sheet UI; live wiring after L) |  |
| L | App composition | Opus | next |  |
| M | Firebase telemetry + release preflight | Sonnet | running | |

## Open items

- Stream L: `HTTPSrokaAPI` takes base URL and token from one snapshot.
- Polish: feature String Catalogs are empty.
- Final review: untested race fixes in H (4) and G (2).
- Merged-state engine `unit` + `build Dev` passed on 5e4392f; not rerun after J.

## Open items for the owner

- `GoogleService-Info.plist` for the iOS app in Firebase project `sroka-95489` → `apps/ios/Config/GoogleService-Info.plist`.
- Apple team id → `apps/ios/Config/Local.xcconfig` (`DEVELOPMENT_TEAM = …`); App IDs `app.sroka`, `app.sroka.share`, App Group `group.app.sroka`.
- `REVIEW_EMAIL` / `REVIEW_OTP` Worker secrets before App Review.
