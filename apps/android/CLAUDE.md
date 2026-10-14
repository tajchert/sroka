# Sroka Android (`apps/android`)

Native Android client (Kotlin, Compose, Room, WorkManager). Own Gradle root — not an npm workspace.
**Binding rulings: `docs/DECISIONS.md`** (A1–A12; overrides template docs). Server contract: repo `docs/api.md`. Progress: `docs/LEDGER.md`.
Built from the ai-android-template (adopted as `app.sroka`); template guides under `docs/` describe the inherited infrastructure (testing layers, screenshots, releasing).

## Commands (run in `apps/android`)
- JDK 21 required: `export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home`
- One module: `./gradlew :core:data:testDebugUnitTest --console=plain 2>&1 | tail -30`
- Gate: `./gradlew testDebugUnitTest lintDebug assembleDebug :app:assembleRelease --console=plain 2>&1 | tail -30`
- Install debug on a running emulator: `./gradlew :app:installDebug`; local backend: repo root `npm run dev -w @sroka/api`, then `adb reverse tcp:8787 tcp:8787` (debug default server `http://localhost:8787`; dev OTP is printed in the wrangler log as `[sroka] OTP for …`).

## Layout
`app` (activities, nav, workers wiring) · `feature/{auth,library,reader,settings}/{api,impl}` · `core/{model,common,designsystem,ui,database,datastore,network,data,testing}` — see DECISIONS A2.

## Conventions
- Local-first: UI reads Room only; user actions write Room + `pending_ops` in one transaction (A7). Network only in SyncEngine/ContentStore.
- Room: never destructive migrations; bump version + Migration + test; schemas exported to `core/database/schemas`.
- No raw exception text in UI; typed errors → string resources. Preserve coroutine cancellation.
- Strings in resources; icon buttons have content descriptions.
