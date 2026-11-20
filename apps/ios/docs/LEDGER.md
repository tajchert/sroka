# iOS build ledger

Integration branch: `t3/ios-app-native`. Brief: `apps/ios/docs/BRIEF.md`.

## Wave 0 (2026-11-20)

- Xcode 27.2, iOS 27.2 simulator runtime, `xcrun swift-format` 6.4.4: OK.
- Template `verify.sh format` and `build Dev` pass on this machine (needs `SIM_OS=27.2`; the template defaults to 27.0).
- Local stack inputs (`.dev.vars`, `node_modules`) are missing in this worktree; needed only for journeys in wave 3 (`npm install`, `npm run dev:setup`).

## Streams

| Stream | Scope | Model | Status | SHA |
|---|---|---|---|---|
| F | Foundation | Opus | running | |
| A | Core logic + network | Sonnet | waiting on F | |
| B | Database | Opus | waiting on F | |
| C | Library UI | Sonnet | waiting on F | |
| D | Reader UI | Sonnet | waiting on F | |
| E | Auth + settings UI | Sonnet | waiting on F | |
| G | Sync | Opus | waiting on A, B | |
| H | Content | Opus | waiting on A, B | |
| I | Session | Opus | waiting on A, B | |
| J | Tags + search UI | Sonnet | waiting on C | |
| K | Share extension | Opus | waiting on G | |
| L | App composition | Opus | waiting on G, H, I | |

## Open items for the owner

- `GoogleService-Info.plist` for the iOS app in Firebase project `sroka-95489` → `apps/ios/Config/GoogleService-Info.plist`.
- Apple team id → `apps/ios/Config/Local.xcconfig` (`DEVELOPMENT_TEAM = …`); App IDs `app.sroka`, `app.sroka.share`, App Group `group.app.sroka`.
- `REVIEW_EMAIL` / `REVIEW_OTP` Worker secrets before App Review.
