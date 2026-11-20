# Architecture

Every section states a decision, why we made it, and how to extend it. If you change one of these decisions, write down why.

This file started from the company iOS template. Conventions (MVVM, DI, navigation, adaptive layout, testing, build configuration, localization) apply to Sroka unchanged; names such as `NotesListViewModel` or `NoteEditorView` refer to the template's sample app and illustrate the rule. Sroka product rulings: `docs/BRIEF.md`, `../../docs/decisions.md`; API contract: `../../docs/api.md`.

## Overview

```
 Sroka (app)        SrokaShare (share extension)       SrokaUITests      ← thin targets
      │ composition root     │ composition root
      ▼                      ▼
 ┌──────────────────────────────────────────────────────────────────────┐
 │ Modules (one local Swift package)                                     │
 │                                                                       │
 │  AuthFeature LibraryFeature TagsFeature SearchFeature ReaderFeature   │
 │  SettingsFeature ShareFeature                          ← features     │
 │        │ (domain protocols, tokens, fakes for previews)               │
 │        ▼                                                              │
 │  SrokaDesign ──► SrokaCore ◄── SrokaTesting (in-memory fakes)         │
 │                     ▲                                                 │
 │  SrokaSync  SrokaContent  SrokaSession                 ← engine       │
 │        │          │            │                                      │
 │        ▼          ▼            ▼                                      │
 │      SrokaNetwork      SrokaDatabase (GRDB)            ← data         │
 └──────────────────────────────────────────────────────────────────────┘
```

**The dependency rule:** features import only `SrokaCore` (models + domain protocols), `SrokaDesign` and `SrokaTesting` (fakes for previews). Features never import each other or any data/engine module. Only the composition roots (app, share extension) import engine and data modules and install live implementations. The package manifest enforces this — an illegal import is a compile error.

**Domain protocols** live in `SrokaCore/Domain` and mirror the Android domain layer: Kotlin `Flow` becomes `AsyncStream` (each access returns a new stream that emits the current value first), `suspend` becomes `async`, and expected failures are result enums. Each has a `TestDependencyKey` whose `testValue` reports an issue when called, so a test that forgets an override fails. Previews and tests install `SrokaTesting` fakes with `withDependencies { $0.useFakes(fakes) }`.

## Modularization

One local Swift package (`Modules`) with one target per module, consumed by a deliberately thin `.xcodeproj`.

**Why:** module boundaries are compiler-enforced, the project file almost never changes (fewer merge conflicts), and previews/tests build only the module they touch. One package (rather than many) keeps a single manifest to maintain.

**Interface/live split:** `PersistenceKit` holds the `NotesRepository` protocol, value types, and lightweight implementations; `PersistenceKitLive` holds SwiftData. Features compile without SwiftData, previews never touch a database, and persistence can be swapped without editing feature code. Apply the same split to any dependency that becomes heavy (large framework import, slow builds, or an SDK you don't want in previews). Lightweight modules like `NetworkingKit` don't need it — split when it hurts, not before.

## MVVM conventions

- One `@Observable @MainActor final class` ViewModel per screen. ViewModels import `Observation`, never `SwiftUI`.
- Views are dumb: every interaction is a method call on the ViewModel; every piece of presentation state (sheet, dialog, alert) is ViewModel state. Scattered view-local `@State` for logic is a code smell — `@State` is for the ViewModel instance itself and purely visual concerns.
- Services arrive via `@Dependency`, always marked `@ObservationIgnored` (required inside `@Observable`).
- Parent creates child ViewModels inside `withDependencies(from: self)` so overrides propagate (see `NotesListViewModel.presentEditor`). Child→parent communication uses an **async** callback (`onFinish`) so tests can await the entire flow.
- Naming: methods are user intentions (`saveButtonTapped`, `noteTapped`), not implementation verbs. Tests then read as user stories.
- Presentation state is a **stored `Bool`** on the ViewModel (`isConfirmingDelete`, `isShowingSyncMessage`), never a `Binding(get:set:)` synthesized in the view. A closure binding allocates a fresh box on every body evaluation and compares unequal each time, so it invalidates dependents for no reason. When the deployment target reaches iOS 27, these collapse into `confirmationDialog(_:item:)` / `alert(_:item:)`, which drive presentation straight from the optional.
- **Never silently drop a draft.** A ViewModel that can replace a child with unsaved changes asks first (`NotesListViewModel.isConfirmingDiscardDraft`, fed by `NoteEditorViewModel.hasUnsavedChanges`); any new way to open or close the editor goes through the same check.
- A collection the view renders is **stored and recomputed on input change**, not a computed filter (`NotesListViewModel.visibleNotes`, recomputed in `didSet` on `notes` and `activeQuery`). A computed property re-runs on every body evaluation, including invalidations that have nothing to do with the data.

**A lesson baked into the code** (`NotesListViewModel.confirmDeleteButtonTapped(_:)`): dialog actions receive the presented value as a parameter rather than re-reading it from presentation state, so the action can't act on the wrong value once that state has moved on. The UI tests caught the original version of this.

## Dependency injection (swift-dependencies)

Each dependency has up to three values:

| Value | Where defined | Purpose |
|---|---|---|
| `liveValue` | Live/implementation module, or assigned at the composition root | Production behavior |
| `testValue` | Interface module | **Unimplemented** — throws/fails so a test that forgets to override fails loudly |
| `previewValue` | Interface module | Seeded in-memory implementation; previews work with zero setup |

- `\.notesRepository` deliberately has **no** static `liveValue`: the composition roots (`AppComposition`, `NoteWidgetBundle.init`) assign it via `prepareDependencies`. That keeps "which store runs" a one-place decision and lets the `-UITests` launch argument swap in an in-memory store.
- **Controlled ambient dependencies — the rule:** never call `Date()`, `UUID()`, or `Task.sleep` in a ViewModel. Use `@Dependency(\.date)`, `@Dependency(\.uuid)`, `@Dependency(\.continuousClock)`. This is what makes every test deterministic (fixed dates, incrementing UUIDs, `TestClock` for debounce).
- **Capture point matters:** `@Dependency` reads the ambient context when the property wrapper is *initialized*. Struct clients built lazily (like `NotesSyncClient.liveValue`) must declare their `@Dependency` values in the builder, not inside the closures (see the comment in `NotesSyncClient.swift`).
- **Cross-cutting concerns are decorators at the composition root:** `WidgetReloadingNotesRepository` wraps the real repository to refresh widget timelines after mutations. Analytics, logging, and cache invalidation belong in the same pattern — feature code stays clean.

## Navigation

- **Tabs are the top level:** `AppTab` (`.notes`, `.settings`) drives a `TabView`, with the selection owned by `AppRouter`. Keep the list short and stable — on iPhone Duo this bar moves to the vertical edge and shares it with the toolbar, and the HIG asks that controls hold the same relative position across device poses.
- **Push navigation:** `AppRouter` (`@Observable`, in `AppFoundation`) owns the selected tab and the Notes tab's `NavigationStack` path of type-safe `AppRoute` values. `router.navigate(to:)` either selects a tab or appends to `path`. **No feature pushes a screen today**: the notes flow is a list plus a detail column, and `path` is always empty — it is the extension point for the first screen a feature needs to push. Both layouts bind the *same* `router.path` (compact: the single `NavigationStack`; regular: the detail column's `NavigationStack`), so a pushed screen survives a fold. The private `RouteDestinations` modifier in `RootView` is the only place that maps routes to concrete views, so features stay ignorant of each other. `AppRoute.settings` resolves to a *tab selection* rather than a push, which is the shape a deep link or widget URL would take.
- **Modal presentation is ViewModel state:** the editor sheet is `editor: NoteEditorViewModel?` (`.sheet(item:)`), the delete dialog is `noteToDelete: Note?`. Unit tests assert full flows (tap → sheet → save → reload) without any UI.

## Adaptive layout (September 2026)

Foldables are a first-class target, not a device the app merely survives. `RootView` picks between two layouts by **horizontal size class**:

| Width | Layout | Editor |
|---|---|---|
| Regular — unfolded Duo, iPad, many landscape phones | `NavigationSplitView`: notes in the sidebar, editor in the detail column | `NoteDetailColumn` |
| Compact — folded Duo, portrait phones, a narrow Split View slice | `NavigationStack`, single column | sheet over the list |

Three rules make this work, and they are the ones to copy into new features:

1. **Branch on size class, never on device, idiom, or orientation.** The same device changes class as it folds, rotates, or enters Split View. There is no `UIScreen.main`, `UIDevice`, or idiom check anywhere in the codebase — keep it that way.
2. **Own the task state above the branch.** `RootView` holds `AppRouter` and `NotesListViewModel`, so `router.path`, the loaded notes, and an unsaved draft inside `notesListViewModel.editor` all outlive a fold. Both layouts read the *same* `editor`; only its presentation differs. A draft started folded is still there unfolded.
3. **Let one piece of state drive both presentations.** `NotesListView.EditorPresentation` says *where* the editor appears; it never decides *whether* one exists. Don't duplicate state per layout — that's how a fold loses a draft.

Beyond navigation: keep controls inside safe areas (leading and trailing insets can differ), give toolbar items both a title and a symbol so they survive vertical bars and overflow menus, and prefer system presentations over custom hinge handling.

### Vertical controls: the tab bar and the toolbar share an edge

On iPhone Duo the system moves the tab bar, the toolbar and the navigation controls to the **side**, preserving vertical space for content ([HIG](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo#Vertical-controls)). The exception is the inner display in portrait, which keeps horizontal bars. You get this by using standard components — the HIG is explicit that you should *not* override default bar placement — but two things are worth declaring, and the template declares both:

**Which bar wins when the edge is crowded.** `RootView` applies `toolbarVerticalCompressionBehavior(.prefersTabBar)`: losing top-level navigation is worse than losing a toolbar item, and the items themselves already say which of *them* should go first. Available `.automatic`, `.prefersTabBar`, `.prefersToolbarItems`.

**Which toolbar item survives compression.** Items overflow **bottom to top**, so the default order is rarely the one you want. `NotesListView` gives "New note" `.visibilityPriority(.high)` — the HIG names Compose in Mail and New Note in Notes as exactly the actions to preserve — and declares Sync inside a `ToolbarOverflowMenu`, so the occasional action starts in the overflow and never competes for the edge. The HIG suggests prioritising whole groups first, then individual items only if you need finer control.

| API | Availability | Used in |
|---|---|---|
| `ToolbarOverflowMenu` | iOS 27.0 | `NotesListView.toolbarContent` |
| `visibilityPriority(_:)` | iOS 27.0 (`.low`/`.high` iOS + macOS only) | `NotesListView.toolbarContent` |
| `toolbarVerticalCompressionBehavior(_:)` | **iOS 27.1** | `RootView.VerticalBarCompression` |

All three are far above the iOS 18 deployment target, so each is gated. Note the two gating shapes: the toolbar builder wraps its *whole* body in one `if #available` with a pre-27 `else`, which is what the SwiftUI 27 toolbar guidance recommends over gating each item; the compression behavior lives in its own `ViewModifier` so the check doesn't split the `TabView` into two branches.

Coverage, and its limit: `testEditorPresentationMatchesWidth` asserts the contract in both orientations on whatever destination it runs on, `testDraftSurvivesWidthClassChange` rotates a live draft across the compact/regular swap (it needs a destination that changes class on rotation, such as iPhone 18 Pro Max, and skips elsewhere), and `SnapshotTests` locks the compact *and* regular layouts. **Folding itself is not automatable** — `simctl` exposes no posture control and XCUITest cannot fold — so unfolded-Duo behavior is a manual Device Hub check.

## Persistence, networking and sync

Owned by the engine streams (see `docs/BRIEF.md`): GRDB database in the environment's App Group (`SrokaDatabase`), HTTP client and wire DTOs (`SrokaNetwork`), outbox sync (`SrokaSync`), article packages and PDFs (`SrokaContent`), auth/session/settings stores (`SrokaSession`). The App Group and keychain group carry `BUNDLE_ID_SUFFIX`, so Dev and Prod never share data. Until they land, `AppComposition` installs the fakes in every build.

## Testing strategy

| Type | Lives in | Tools | Use for |
|---|---|---|---|
| Unit | `Modules/Tests/<Module>Tests` | Swift Testing, `withDependencies`, `TestClock` | Every ViewModel interaction, every client, every repository. The default — write these first. |
| Snapshot | `Modules/Tests/SnapshotTests` | swift-snapshot-testing, `.snapshots(record: .missing)` | Layout of DesignSystem components and full screens, light + dark. |
| UI (XCUITest) | `UITests/` | `-UITests` launch argument, accessibility identifiers | A handful of critical end-to-end flows only. Slow — don't test logic here. |

Rules of thumb:
- Logic → unit test. Looks → snapshot. "Does the whole thing hang together" → UI test.
- `NotesFeatureTests` is the exemplar of coverage: every user interaction, error path, and async behavior (debounce + cancellation with `TestClock`).
- Test names are sentence-case raw identifiers — ``@Test func `Search is debounced`()`` — so failures read as prose in the test log rather than as run-together camelCase. Two exceptions: `SnapshotTests` keeps plain identifiers because swift-snapshot-testing derives the reference filename from `#function`, and `UITests/` stays XCTest (XCUIAutomation can't use Swift Testing), which requires the `test` prefix.
- Tests that differ only by their input are parameterized with `@Test(arguments:)` — see `HTTPClientTests` — so each case is reported separately.
- Assert with `#expect` / `#require`, not `Issue.record` inside a `do`/`catch`: the macros capture and report the surrounding expression, while `Issue.record` reports only the message it was handed.
- Accessibility identifiers follow `feature.element` (`notesList.addButton`, `noteEditor.saveButton`). Never use duplicate visible labels for distinct actions — UI-test queries become ambiguous (why the dialog says "Delete note" while the swipe action says "Delete").
- The `-UITests` launch argument is the app's *only* test hook, handled entirely in `AppComposition`.
- Snapshot references are tied to the simulator OS version; re-record when the fleet upgrades (delete `__Snapshots__`, run twice).

## Build configuration

Use Xcode 27.2 or later with Swift 6.4 and the iOS 27.2 SDK. `Modules/Package.swift` sets the compiler/tooling floor; `SWIFT_VERSION = 6.0` and `swiftLanguageModes: [.v6]` select the language mode. The deployment target is iOS 27.0 across app, share extension, tests and package. New SDK APIs require availability checks when used. After changing package versions, copy `Modules/Package.resolved` over `Sroka.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

One SDK 27 change to know about: `@State` is now a macro rather than a property wrapper. If you add an `init` to a view that has `@State` and hit *"variable used before being initialized"*, the fix is to **drop the initial value at the declaration** and assign only in the `init` — not to reorder the assignments, which compiles but leaves the view seeing the declaration's value at runtime.

Two axes — build type × environment — give four configurations: `Debug-Dev`, `Debug-Prod`, `Release-Dev`, `Release-Prod`. The xcconfig include graph keeps each value defined exactly once:

```
Debug-Dev.xcconfig ─┬─ Debug.xcconfig ── Shared.xcconfig
                    └─ Dev.xcconfig
(and the other three combinations likewise)
```

Environment values flow: `xcconfig` → build setting → `Info.plist` (`$(API_BASE_URL)`, `$(APP_GROUP_IDENTIFIER)`) → `AppEnvironment(infoDictionary:)` → `@Dependency(\.appEnvironment)` → code. No `#if DEBUG` environment switching, no hardcoded URLs.

Gotcha worth knowing: `//` starts a comment in xcconfig, so URLs are written `https:/$()/host` (the empty `$()` splits the slashes).

### Enhanced Security

`Shared.xcconfig` sets `ENABLE_ENHANCED_SECURITY` and `ENABLE_POINTER_AUTHENTICATION`; `App/Sroka.entitlements` and `Share/SrokaShare.entitlements` carries the matching `com.apple.security.hardened-process` keys. Both halves are required — the build setting alone is inert, and the entitlements alone do nothing at compile time. Pointer authentication adds an `arm64e` slice to device builds (`ARCHS = arm64 arm64e`); the simulator SDK drops it automatically, so nothing special is needed for local runs. Turn `ENABLE_POINTER_AUTHENTICATION` off for a target only if it links a binary dependency that ships no `arm64e`.

This is nearly free here because the app is pure Swift: the settings this cascades — C++ stdlib hardening, typed allocators, `-Wshadow` — have no C, C++, or Objective-C to act on. Adding such code later means re-checking the build. The share extension inherits the build settings.

## Localization

Every module with UI needs two things, and `NotesFeature` is the worked example:

1. A `Localizable.xcstrings` in the target's source directory, declared as `resources: [.process("Localizable.xcstrings")]` in `Package.swift`. This is what gives the target a resource bundle — `#bundle` is a compile error without it. `defaultLocalization` is set once on the package.
2. `bundle: #bundle` on every user-facing literal. Package code that omits it is looked up in `Bundle.main`, **the lookup fails silently**, and the string ships untranslated. Modifiers that take only a `LocalizedStringKey` have nowhere to put a bundle — use their `Text` overload (see `NoteEditorView`'s `navigationTitle` and `Button` labels).

Text that originates in a view model or any other non-view type is a `LocalizedStringResource`, not a `String`, so resolution happens at display time with the right locale (`NoteEditorViewModel.saveError`). Add `comment:` for translators, especially on interpolated strings.

## Adding a new feature module — checklist

1. In `Modules/Package.swift`: add a `.target` (deps: `AppFoundation`, `DesignSystem`, interface modules only), a `.testTarget`, and a `.library` product. Add `Localizable.xcstrings` + `resources:` if the module has UI strings.
2. Create `Sources/<Name>Feature/` with `<Screen>ViewModel.swift` + `<Screen>View.swift` pairs. Public entry view; previews on everything. Factor each section of a screen as its own `View` type, not a `@ViewBuilder` computed property on the parent — a computed property is inlined into the enclosing body and shares its invalidation boundary (`NotesListView` / `NotesListContent`).
3. Write the ViewModel unit tests first (`withDependencies` + in-memory doubles). Add a snapshot test for the main screen.
4. If the feature is pushed, make three edits: add a case to `AppRoute`, add a push branch (select the tab, then `path.append(route)`) to `AppRouter.navigate(to:)`, and add a case to `RouteDestinations` in `RootView`.
5. Add the product to the app target's package dependencies (Xcode: target → Frameworks → +).
6. Extend UI tests only if the feature is a critical flow.

## Known limitations

- Every build runs on in-memory fakes until the engine streams land.
- No CI configuration.
- Package unit tests can't run through the app scheme (Xcode limitation for dependency packages); use `scripts/verify.sh unit`.
