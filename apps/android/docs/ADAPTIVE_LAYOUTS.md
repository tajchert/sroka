# Adaptive layouts

Foldables, tablets and desktop windows are supported device classes here, not
edge cases. Nothing in the app branches on a device type; every decision is made
from the window the app is currently given, which is the only thing that stays
correct when a device folds, unfolds or is resized in a desktop window.

## What is implemented

**List-detail through Navigation 3 Scenes.** `SrokaNavHost` creates a
`ListDetailSceneStrategy` and passes it to `NavDisplay`. Each entry declares its
pane role as metadata: `TaskListRoute` is the list pane, `TaskDetailRoute` is the
detail pane. On a phone or a folded cover display the top entry fills the window;
on an unfolded foldable, tablet or desktop window both panes render side by side.

This is deliberately the Scenes approach rather than `ListDetailPaneScaffold`.
A scaffold needs its own selection state next to the back stack, which leaves two
sources of truth to keep in sync. With scene strategies the back stack remains
the only navigation state at every window size.

**A detail placeholder.** `detailPlaceholder` fills the detail pane when both
panes are visible but nothing is selected, so a wide window does not open with
half of it blank.

**No back arrow in two-pane mode.** When the list is still on screen there is
nothing to go back to, so `showDetailBackButton` is false and `SrokaTopAppBar`
draws no navigation icon.

**An adaptive grid.** The task list is a `LazyVerticalGrid` with
`GridCells.Adaptive`, fitting as many 360dp columns as the window allows. A
single-column grid renders identically to the list it replaced, so nothing
regresses on a phone.

**Feature-host parity.** `samples/tasks-app` configures the same strategy and
directive as the app. A layout verified in the host behaves the same in the
complete app; divergence between the two is the main cost of running a host.

## Verifying a change

Screenshot references cover phone, folded and unfolded foldable, tablet and
desktop widths plus font scale 1.5. See
[Compose screenshot testing](SCREENSHOT_TESTING.md).

Static previews cannot express hinge position, tabletop or book posture,
hardware keyboards or pointer precision. Verify those on a foldable emulator.

## Deliberately not adopted

| API | Why not |
|---|---|
| `Grid`, `FlexBox` | Experimental in Compose 1.11; outside the stable-dependency policy. `LazyVerticalGrid` covers the sample's needs. |
| `mediaQuery` | Experimental. It is the right API for posture, pointer precision and keyboard presence when a product needs them. |
| `NavigationSuiteScaffold` | The sample has a single top-level destination, so there is no navigation bar to adapt into a rail. Adopt it as soon as a second top-level destination appears, rather than adding a bottom bar first. |
| Compose Styles API | Experimental, and requires alpha `foundation`. |

`androidx.compose.material3.adaptive` 1.3.0 is a stable release, but some of its
APIs - `currentWindowAdaptiveInfoV2`, the pane metadata helpers - still require
`@OptIn(ExperimentalMaterial3AdaptiveApi::class)`. That opt-in is accepted here
because the artifact itself is stable; expect these signatures to change before
the annotation is removed.

## Next steps for a product

- Add a supporting-pane scene where a screen has a genuine supporting
  relationship, using `SupportingPaneSceneStrategy`.
- Adopt `NavigationSuiteScaffold` when a second top-level destination appears.
- Constrain text measure on very wide windows; a full-width paragraph on a
  desktop window is hard to read even when the layout is correct.
- Hide app bars on scroll with `enterAlwaysScrollBehavior` or
  `exitUntilCollapsedScrollBehavior` where content deserves the space.
