# Agent guidance (Sroka Android)

Start with [CLAUDE.md](CLAUDE.md) (commands, layout, conventions), then [DECISIONS](docs/DECISIONS.md) (binding rulings) and [README](README.md) (feature inventory). `MODERN_ANDROID_GUIDE.md` is optional template background, not a requirement.

- Features may depend on another feature's API, never its implementation. Core modules do not depend on features.
- Room is the source of truth; never use destructive migrations. User writes go through Room + `pending_ops` (A7).
- ViewModels expose typed state/errors. Resolve user-facing text from resources, preserve cancellation, collect state with lifecycle awareness.
- Use [Android CLI and official skills](docs/AGENT_SETUP.md) for current platform guidance.
- Before completion run the applicable [verification commands](docs/TESTING.md#commands). Report any checks that could not run.
- Update the README inventory when behavior, configuration or workflows change.
