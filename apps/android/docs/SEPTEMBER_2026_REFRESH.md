# September 2026 refresh

Reviewed **19 September 2026**, from commit `34132b6` (11 July 2026).
The executable baseline is the version catalog and Gradle wrapper, not a forecast
of upcoming releases. Versions were checked against Google Maven, Maven Central,
Gradle's release service, and the maintainers' release pages.

## Version changes

| Component | July baseline | September baseline |
|---|---|---|
| Android target SDK | 36 | 37 (Android 17) |
| Android Gradle Plugin | 9.2.1 | 9.4.1 |
| Gradle wrapper | 9.5.1 | 9.7.1 |
| Kotlin / Compose compiler / serialization plugin | 2.4.0 | 2.4.20 |
| KSP | 2.3.9 | 2.3.12 |
| Compose BOM | 2026.06.01 | 2026.09.00 |
| Navigation 3 | 1.1.4 | 1.1.7 |
| Room | 2.8.4 | 2.8.5 |
| OkHttp | 5.4.0 | 5.5.0 |
| Coil (catalog option) | 3.5.0 | 3.6.3 |
| AppCompat (catalog option) | 1.7.1 | 1.8.0 |
| Robolectric (catalog option) | 4.16.1 | 4.17 |
| Compose screenshot tooling | 0.0.1-alpha14 | 0.0.1-alpha16 |

Keep compile SDK 37, min SDK 26, JDK 21 for Gradle, and Java 17 bytecode.
Hilt 2.60.1, AndroidX Hilt 1.4.0, Lifecycle 2.11.0, Activity 1.13.0,
Core 1.19.0, DataStore 1.2.1, Coroutines 1.11.0, Serialization 1.11.0,
Retrofit 3.0.0, and Turbine 1.2.1 remain current stable choices. AndroidX Test
Runner 1.7.0, JUnit extension 1.3.0, and Espresso 3.7.0 are unchanged.

At the September review, the stable runtime policy excluded Navigation 3 1.2 RC, Material 3 previews,
Serialization 1.12 RC, and AGP 9.5 previews. Screenshot tooling remains the
existing, explicitly experimental test-only exception. Alpha16 removes the
standalone threshold DSL; comparisons now use the default exact match. Native
AGP screenshot suites are deferred until their required AGP version is stable.

## Architecture and patterns

Keep Compose, app-owned typed Navigation 3 keys, destination-scoped Hilt
ViewModels, lifecycle-aware StateFlow collection, and Room as the read source.
Use cases remain optional and justified by reusable business logic. The
feature API/implementation split and small feature host remain useful here;
do not copy a reference app's entire module graph into every new product.

Create and delete completion now lives in observable state. Compose performs
navigation while resumed, rather than handing a screen callback to a coroutine
in a ViewModel. Creation/deletion reject duplicate submissions while pending
or completed. Task creation preserves small drafts in SavedStateHandle. Write
errors are visible without discarding the draft or loaded tasks, and cancellation
propagates normally. Both navigation hosts retain the root entry when handling
back callbacks.

Saved state is not durable task scheduling or exactly-once persistence. A process
can die after a database commit but before UI completion is observed; products
requiring deduplication must persist operation identity transactionally and/or
use backend idempotency. The sample still uses a fake backend and destructive
snapshot refresh, with the limits documented in [SYNC.md](SYNC.md).

AGP's built-in Kotlin and KSP remain enabled. Remove root `subprojects` dependency
injection and the blanket Kotlin metadata force: instrumented-test dependencies
belong to their modules, and the upgraded toolchain resolves without that global
override. Shared convention plugins are a sensible next step when more modules
or teams justify a dedicated build-logic module.

CI explicitly installs SDK 37, compiles the existing instrumentation APKs, and
checks the minified release with R8 as well as debug builds, unit tests, and lint.
Actions use immutable commits with version comments and Dependabot updates.
The regenerated wrapper uses an official distribution SHA-256; its JAR was
checked against Gradle's published wrapper checksum.

## Follow-up work applied after the refresh

Reviewed against the Google Android skills repository
(`developer.android.com/tools/agents/android-skills`):

- Edge-to-edge and IME insets corrected; `adjustResize` added to both hosts.
- Shared form-factor and font-scale previews; screenshot coverage widened from
  one phone size to five window sizes plus font scale 1.5.
- Adaptive list-detail via Navigation 3 scenes (`adaptive-navigation3` 1.3.0,
  a stable release) and an adaptive task grid.
- Validated deep links with a synthetic back stack, covering cold and warm start.
- Compose behaviour and navigation tests moved onto Robolectric so they run
  without an emulator; aggregated Kover coverage added.

At the September review, Navigation 3's built-in deep-link API was only in
1.2.0-rc01, so matching used the 1.1.7 baseline. The October follow-up below
replaces it with the stable API. `androidx.compose.material3.adaptive` 1.3.0
is stable but still requires `@OptIn(ExperimentalMaterial3AdaptiveApi::class)`
for several of its APIs.

## Verification commands

Validation on September 19: **26 unit tests, 24 screenshot tests, and 10 device
tests passed** (nine feature tests plus one Room migration on an Android 17
emulator). Debug builds, debug/release lint, instrumentation APK compilation,
and the minified unsigned release build passed. Three reviewed component
references were updated for card-shadow/edge rendering changes; all 13 existing
screen references matched. GitHub-hosted CI and API 26 device execution were not
run locally.

The refresh also makes AndroidJUnit4 discovery explicit in the Compose device
tests; a successful Gradle task with zero discovered tests is not a passing UI
suite. Inspect the XML test counts alongside the task exit code.

```bash
./gradlew testDebugUnitTest lintDebug assembleDebug \
  :core:database:assembleDebugAndroidTest \
  :feature:tasks:impl:assembleDebugAndroidTest \
  :app:lintRelease :app:assembleRelease

./gradlew :core:designsystem:validateDebugScreenshotTest \
  :core:ui:validateDebugScreenshotTest \
  :feature:tasks:impl:validateDebugScreenshotTest

# Requires an emulator/device; APK compilation alone does not execute these tests.
./gradlew :core:database:connectedDebugAndroidTest \
  :feature:tasks:impl:connectedDebugAndroidTest
```

Before shipping a product, exercise API 26 and 37, process recreation, rotation,
large fonts, keyboard/IME insets, predictive back, tablet/foldable resizing, and
the actual minified release. Add baseline profiles and benchmarks for real
journeys instead of treating debug responsiveness as performance evidence.

## Sources

- [AGP 9.4 compatibility](https://developer.android.com/build/releases/agp-9-4-0-release-notes) and [published AGP versions](https://dl.google.com/dl/android/maven2/com/android/tools/build/gradle/maven-metadata.xml).
- [Gradle releases](https://gradle.org/releases/) and [wrapper verification](https://docs.gradle.org/current/userguide/gradle_wrapper.html#sec:verification).
- [Kotlin 2.4.20](https://kotlinlang.org/docs/whatsnew2420.html) and [KSP releases](https://github.com/google/ksp/releases).
- [AndroidX releases](https://developer.android.com/jetpack/androidx/versions), [Room](https://developer.android.com/jetpack/androidx/releases/room), and [Compose BOM metadata](https://dl.google.com/dl/android/maven2/androidx/compose/compose-bom/maven-metadata.xml).
- [Android 17 SDK](https://developer.android.com/about/versions/17/setup-sdk) and [target behavior changes](https://developer.android.com/about/versions/17/behavior-changes-17).
- [UI events and state](https://developer.android.com/topic/architecture/ui-layer/events) and [saving UI state](https://developer.android.com/topic/libraries/architecture/saving-states).
- [Screenshot tooling release notes](https://developer.android.com/studio/preview/compose-screenshot-testing-release-notes).
- [OkHttp metadata](https://repo.maven.apache.org/maven2/com/squareup/okhttp3/okhttp/maven-metadata.xml), [Coil releases](https://github.com/coil-kt/coil/releases), and [Robolectric releases](https://github.com/robolectric/robolectric/releases).
- [Dagger](https://github.com/google/dagger/releases), [Coroutines](https://github.com/Kotlin/kotlinx.coroutines/releases), [Serialization](https://github.com/Kotlin/kotlinx.serialization/releases), [Retrofit](https://github.com/square/retrofit/releases), and [Turbine](https://github.com/cashapp/turbine/releases).

## 1 October follow-up: Navigation 3 1.2.0

Navigation 3 1.2.0 became stable on 23 September, after this refresh.
The catalog now pins 1.2.0, and the Tasks deep-link contract uses
`UriDeepLinkMatcher`, `DeepLinkRequest`, and `.withBackStack` instead of manual
path-to-route matching. The stable runtime policy remains in place. Keep
argument validation and the existing cold/warm back-stack installation.
See [release notes](https://developer.android.com/jetpack/androidx/releases/navigation3#1.2.0)
and [deep-link handling](DEEP_LINKS.md).
