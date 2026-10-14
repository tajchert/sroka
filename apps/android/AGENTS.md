# Android starter guidance

Read [README](README.md) for implemented behavior and [Testing](docs/TESTING.md) for commands. The longer modern Android guide contains optional patterns, not requirements.

- Keep Tasks as a small executable example. Do not add modules, SDKs, or production services without a concrete requirement.
- Features may depend on another feature's API, never its implementation. Core modules do not depend on features.
- Room is the task source of truth. Never import a remote snapshot on startup or use destructive migrations. Demo replacement requires user confirmation.
- ViewModels expose typed state/errors. Resolve user-facing text from resources in Compose, preserve cancellation, and collect state with lifecycle awareness.
- Use [Android CLI and official skills](docs/AGENT_SETUP.md) for current guidance. Keep stable dependencies; screenshot testing is the existing documented alpha exception.
- Before completion run the applicable [verification commands](docs/TESTING.md#commands). Report any checks that could not run.
- For UI changes validate screenshots and inspect changed references: [screenshot workflow](docs/SCREENSHOT_TESTING.md). Never regenerate references merely to hide an unexplained failure.
- For database/lifecycle/accessibility changes run the device tests in [Testing](docs/TESTING.md). Benchmark timing claims require a physical device.
- When adopting this template use [the adoption workflow](docs/ADOPTING.md), including profile regeneration and App Link configuration.
- Update the README inventory and relevant guides whenever implemented behavior, configuration, or developer workflows change. Keep commands in their canonical guide and link to them.
