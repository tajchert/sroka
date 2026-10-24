package app.sroka.navigation

import app.sroka.core.model.LibraryTab
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.LocalMinimumInteractiveComponentSize
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Surface
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuite
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffoldLayout
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf

import androidx.compose.runtime.setValue
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfoV2
import androidx.compose.material3.adaptive.layout.PaneScaffoldDirective
import androidx.compose.material3.adaptive.layout.PaneExpansionAnchor
import androidx.compose.material3.adaptive.layout.calculatePaneScaffoldDirective
import androidx.compose.material3.adaptive.layout.rememberPaneExpansionState
import androidx.compose.material3.adaptive.navigation.BackNavigationBehavior
import androidx.compose.material3.adaptive.navigation3.rememberListDetailSceneStrategy
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteDefaults
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffoldDefaults
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteType
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.navigation3.rememberViewModelStoreNavEntryDecorator
import androidx.navigation3.runtime.NavBackStack
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.runtime.rememberSaveableStateHolderNavEntryDecorator
import androidx.navigation3.ui.NavDisplay
import app.sroka.R
import app.sroka.core.model.SessionState
import app.sroka.core.ui.adaptive.LocalPaneLayout
import app.sroka.core.ui.adaptive.PaneLayout
import app.sroka.core.ui.posture.rememberReaderLayout
import app.sroka.core.ui.posture.shellLayoutFor
import app.sroka.feature.auth.api.AuthKey
import app.sroka.feature.auth.impl.navigation.authEntries
import app.sroka.feature.library.api.SearchKey
import app.sroka.feature.library.api.TagItemsKey
import app.sroka.feature.library.api.TagsKey
import app.sroka.feature.library.impl.navigation.libraryEntries
import app.sroka.feature.reader.api.ReaderKey
import app.sroka.feature.reader.impl.navigation.readerEntries
import app.sroka.feature.settings.api.ExportKey
import app.sroka.feature.settings.api.ImportKey
import app.sroka.feature.settings.api.SettingsChoiceKey
import app.sroka.feature.settings.api.SettingsKey
import app.sroka.feature.settings.impl.navigation.settingsEntries
import kotlinx.coroutines.launch

/**
 * App shell: one Navigation 3 back stack plus a [NavigationSuiteScaffold] (bottom bar on phones,
 * rail on larger windows) for the top-level tabs (DECISIONS A11). The bar is shown only while a tab
 * root is on top; reader, settings, tag lists and sign-in are full screen.
 *
 * The session drives the stack: signed out ⇒ only [AuthKey]; signing in replaces it with My List.
 * An expired session keeps the library (local-first) and opens sign-in on demand.
 * Features never see each other's keys; their navigation callbacks are mapped to keys here.
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
fun SrokaApp(
    session: SessionState,
    onUndoArchive: (itemId: String) -> Unit,
    modifier: Modifier = Modifier,
    openItemId: String? = null,
    onOpenItemConsumed: () -> Unit = {},
) {
    val signedOut = session is SessionState.SignedOut
    val startKey = if (signedOut) AuthKey else TopLevelDestination.MY_LIST.key
    val backStack = rememberNavBackStack(startKey)
    val snackbarHostState = remember { SnackbarHostState() }

    // Signed out: only sign-in. Signed in: drop any sign-in screen (also the one opened from the
    // Expired banner, which keeps the library underneath). Expired: leave the stack alone.
    LaunchedEffect(session::class) {
        when (session) {
            SessionState.SignedOut ->
                if (backStack.toList() != listOf(AuthKey)) backStack.replaceAll(AuthKey)
            is SessionState.SignedIn -> if (AuthKey in backStack) {
                val rest = backStack.filter { it != AuthKey }
                backStack.replaceAll(*rest.ifEmpty { listOf(TopLevelDestination.MY_LIST.key) }.toTypedArray())
            }
            is SessionState.Expired -> Unit
        }
    }

    // Share-sheet deep link: open the article on top of the current stack once signed in.
    LaunchedEffect(openItemId, session::class) {
        if (openItemId != null && session !is SessionState.SignedOut) {
            backStack.openReader(openItemId)
            onOpenItemConsumed()
        }
    }

    val archivedMessage = stringResource(R.string.reader_archived)
    val undoLabel = stringResource(R.string.reader_archived_undo)
    val scope = rememberCoroutineScope()
    val onArchived: (String) -> Unit = { itemId ->
        if (backStack.size > 1) backStack.removeLastOrNull()
        scope.launch {
            snackbarHostState.currentSnackbarData?.dismiss()
            val result = snackbarHostState.showSnackbar(
                message = archivedMessage,
                actionLabel = undoLabel,
                duration = SnackbarDuration.Short,
            )
            if (result == SnackbarResult.ActionPerformed) onUndoArchive(itemId)
        }
    }

    // Wide windows show the reader next to the list (list-detail scene), so the tab bar stays.
    val windowAdaptiveInfo = currentWindowAdaptiveInfoV2()
    // The 24dp gutter between the panes holds the drag handle (R13); single pane has no gutter.
    val windowDirective = remember(windowAdaptiveInfo) {
        val base = calculatePaneScaffoldDirective(windowAdaptiveInfo)
        base.copy(horizontalPartitionSpacerSize = if (base.maxHorizontalPartitions > 1) PaneGutter else 0.dp)
    }
    // Tabletop (R15.2) with a reader on top: the reader takes the whole window, so no navigation suite and one
    // pane. The back stack is untouched, leaving tabletop restores the previous layout.
    val top = backStack.lastOrNull()
    val shell = shellLayoutFor(rememberReaderLayout(), readerOnTop = top is ReaderKey)
    val directive = if (shell.forceSinglePane) {
        windowDirective.copy(maxHorizontalPartitions = 1, horizontalPartitionSpacerSize = 0.dp)
    } else {
        windowDirective
    }
    // Window truth for back-stack decisions; what is drawn side by side is `drawnTwoPane`.
    val twoPane = windowDirective.maxHorizontalPartitions > 1
    val drawnTwoPane = directive.maxHorizontalPartitions > 1
    val current = currentTab(backStack, twoPane)
    val adaptiveType = NavigationSuiteScaffoldDefaults.calculateFromAdaptiveInfo(windowAdaptiveInfo)
    val layoutType = if (current != null && !shell.hideNavigation) adaptiveType else NavigationSuiteType.None
    val railShown = layoutType.isRail()
    // The rail's "Save link" button asks the next list that is shown to open its add-link dialog.
    var addLinkRequested by rememberSaveable { mutableStateOf(false) }
    val email = (session as? SessionState.SignedIn)?.email ?: (session as? SessionState.Expired)?.email.orEmpty()

    val itemColors = NavigationSuiteDefaults.itemColors(
        navigationBarItemColors = NavigationBarItemDefaults.colors(
            indicatorColor = MaterialTheme.colorScheme.primaryContainer,
            selectedIconColor = MaterialTheme.colorScheme.onPrimaryContainer,
            selectedTextColor = MaterialTheme.colorScheme.onPrimaryContainer,
        ),
    )

    Surface(
        modifier = modifier,
        color = MaterialTheme.colorScheme.background,
        contentColor = MaterialTheme.colorScheme.onBackground,
    ) {
        NavigationSuiteScaffoldLayout(
            layoutType = layoutType,
            navigationSuite = {
                if (railShown) {
                    val destinations = TopLevelDestination.entries.map {
                        RailDestination(stringResource(it.label), it.unselectedIcon, it.selectedIcon)
                    }
                    SrokaRail(
                        destinations = destinations,
                        selectedIndex = TopLevelDestination.entries.indexOf(current),
                        avatarLetter = railAvatarLetter(email),
                        onSaveLink = {
                            // Tags has no add-link dialog: go to My List first.
                            if (current == TopLevelDestination.TAGS) backStack.navigateToTopLevel(TopLevelDestination.MY_LIST)
                            addLinkRequested = true
                        },
                        onSelect = { backStack.navigateToTopLevel(TopLevelDestination.entries[it]) },
                        onOpenSettings = { backStack.add(SettingsKey) },
                    )
                } else {
                    NavigationSuite(layoutType = layoutType) {
                        TopLevelDestination.entries.forEach { destination ->
                            val selected = destination == current
                            item(
                                selected = selected,
                                onClick = { backStack.navigateToTopLevel(destination) },
                                icon = {
                                    Icon(
                                        imageVector = if (selected) destination.selectedIcon else destination.unselectedIcon,
                                        contentDescription = null,
                                    )
                                },
                                label = { Text(stringResource(destination.label)) },
                                colors = itemColors,
                            )
                        }
                    }
                }
            },
        ) {
            Box(Modifier.fillMaxSize()) {
                // Live layout for entry content (NavDisplay keeps content across window changes).
                CompositionLocalProvider(LocalPaneLayout provides PaneLayout(twoPane = drawnTwoPane, railShown = railShown)) {
                    SrokaNavDisplay(
                        backStack = backStack,
                        directive = directive,
                        onArchived = onArchived,
                        twoPane = twoPane,
                        drawnTwoPane = drawnTwoPane,
                        addLinkRequested = { addLinkRequested },
                        onAddLinkHandled = { addLinkRequested = false },
                    )
                }
                // App-level snackbar for results that outlive a screen (archive from the reader).
                // On tab roots it sits above the list's FAB, like a Scaffold snackbar would.
                val placement = snackbarPlacement(twoPane, railShown, hasFab = current != null)
                SnackbarHost(
                    hostState = snackbarHostState,
                    modifier = Modifier
                        .align(if (placement.startAligned) Alignment.BottomStart else Alignment.BottomCenter)
                        .then(placement.width?.let { Modifier.widthIn(max = it) } ?: Modifier)
                        .windowInsetsPadding(WindowInsets.navigationBars)
                        .padding(bottom = placement.bottomClearance),
                )
            }
        }
    }
}

private fun NavigationSuiteType.isRail(): Boolean = this != NavigationSuiteType.None &&
    this != NavigationSuiteType.NavigationBar &&
    this != NavigationSuiteType.ShortNavigationBarCompact &&
    this != NavigationSuiteType.ShortNavigationBarMedium

/** Gutter between list and detail; hosts the drag handle. */
private val PaneGutter = 24.dp

/** Divider anchors (R13): min 300dp per pane, list 360dp, 50 %. */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
private val PaneAnchors = listOf(
    PaneExpansionAnchor.Offset.fromStart(0.dp), // COLLAPSED_INDEX: full-width reading (R14.3)
    PaneExpansionAnchor.Offset.fromStart(300.dp),
    PaneExpansionAnchor.Offset.fromStart(360.dp),
    PaneExpansionAnchor.Proportion(0.5f),
    PaneExpansionAnchor.Offset.fromEnd(300.dp),
)

@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
private fun SrokaNavDisplay(
    backStack: NavBackStack<NavKey>,
    directive: PaneScaffoldDirective,
    onArchived: (itemId: String) -> Unit,
    twoPane: Boolean,
    drawnTwoPane: Boolean,
    addLinkRequested: () -> Boolean,
    onAddLinkHandled: () -> Unit,
) {
    // PopLatest: with the default (pop until the scaffold value changes) system Back from the two-pane
    // list+reader popped the list too (list+placeholder has the same scaffold value) and closed the app.
    // Snap points for the divider: each pane keeps at least 300dp, the list can sit at 360dp or 50 %.
    // R14.3: the anchor index at rest and the last non-collapsed one are saved here so rotation keeps both.
    var anchorIndex by rememberSaveable { mutableIntStateOf(-1) }
    var listIndex by rememberSaveable { mutableIntStateOf(DEFAULT_LIST_INDEX) }
    // Only the restored value seeds the state: passing the live index would recreate it on every change.
    val initialAnchorIndex = remember { anchorIndex }
    val expansionState = rememberPaneExpansionState(anchors = PaneAnchors, initialAnchoredIndex = initialAnchorIndex)
    LaunchedEffect(expansionState) {
        snapshotFlow { PaneAnchors.indexOf(expansionState.currentAnchor) }.collect {
            anchorIndex = it
            listIndex = rememberedIndex(it, listIndex)
        }
    }
    val scope = rememberCoroutineScope()
    // Entry callbacks and getters below outlive recompositions: read the window state through State.
    val twoPaneState = rememberUpdatedState(twoPane)
    val drawnTwoPaneState = rememberUpdatedState(drawnTwoPane)
    val detailItemId = detailPaneItemId(backStack, twoPane)
    val expanded = twoPane && anchorIndex == COLLAPSED_INDEX
    // Read through State: NavDisplay keeps entry content while the back stack is unchanged, so a plain
    // Boolean captured here would go stale when only the divider moves.
    val expandedState = rememberUpdatedState(expanded)
    val restoreList: () -> Unit = {
        scope.launch { expansionState.animateTo(PaneAnchors[restoreIndex(listIndex, PaneAnchors.size)]) }
    }
    // Without an open article there is nothing to read full width: bring the list back.
    LaunchedEffect(detailItemId, twoPane) { if (detailItemId == null && anchorIndex == COLLAPSED_INDEX) restoreList() }
    val listDetailStrategy = rememberListDetailSceneStrategy<NavKey>(
        backNavigationBehavior = BackNavigationBehavior.PopLatest,
        directive = directive,
        paneExpansionState = expansionState,
        // Dragging this handle in the gutter resizes the panes (PaneExpansionState).
        paneExpansionDragHandle = { state ->
            val interactionSource = remember { MutableInteractionSource() }
            PaneDividerHandle(
                Modifier.paneExpansionDraggable(state, LocalMinimumInteractiveComponentSize.current, interactionSource),
            )
        },
    )
    val goBack: () -> Unit = { if (backStack.size > 1) backStack.removeLastOrNull() }
    NavDisplay(
        backStack = backStack,
        onBack = goBack,
        sceneStrategies = listOf(listDetailStrategy),
        // Specifying entryDecorators replaces the defaults, so the saveable-state
        // decorator is listed explicitly next to the per-entry ViewModel store.
        entryDecorators = listOf(
            rememberSaveableStateHolderNavEntryDecorator(),
            rememberViewModelStoreNavEntryDecorator(),
        ),
        entryProvider = entryProvider {
            authEntries()
            libraryEntries(
                // In two-pane mode a new selection replaces the open article instead of stacking.
                onOpenItem = backStack::openReader,
                onOpenTag = { name -> backStack.openTag(name, twoPaneState.value) },
                onOpenSettings = { backStack.add(SettingsKey) },
                onCloseTag = { key ->
                    val i = backStack.lastIndexOf(key)
                    if (i > 0) backStack.subList(i, backStack.size).clear()
                },
                // From the Expired banner: sign in on top of the library; success pops it.
                onSignIn = { if (backStack.lastOrNull() != AuthKey) backStack.add(AuthKey) },
                onOpenSearch = { tab -> backStack.openSearch(tab, twoPaneState.value) },
                onOpenTagsSearch = { backStack.openSearch(LibraryTab.MY_LIST, twoPaneState.value, fromTags = true) },
                onCloseSearch = { key ->
                    val i = backStack.lastIndexOf(key)
                    if (i > 0) backStack.subList(i, backStack.size).clear()
                },
                selectedTag = { selectedTagName(backStack, twoPaneState.value) },
                selectedItemId = { detailPaneItemId(backStack, twoPaneState.value) },
                addLinkRequested = addLinkRequested,
                onAddLinkHandled = onAddLinkHandled,
            )
            readerEntries(
                onBack = goBack,
                onOpenItem = backStack::openReader,
                onArchived = onArchived,
                detailPaneActive = { drawnTwoPaneState.value && detailPaneItemId(backStack, twoPaneState.value) != null },
                isExpanded = { expandedState.value },
                onToggleExpanded = {
                    if (expandedState.value) restoreList()
                    else scope.launch { expansionState.animateTo(PaneAnchors[COLLAPSED_INDEX]) }
                },
            )
            settingsEntries(
                onBack = goBack,
                onOpenImport = { backStack.openSettingsDetail(ImportKey) },
                onOpenExport = { backStack.openSettingsDetail(ExportKey) },
                onOpenChoice = { backStack.openSettingsDetail(SettingsChoiceKey(it)) },
                topKey = { backStack.lastOrNull() },
            )
        },
    )
}

/** Opens a settings sub-page; one already open (import, export, choice page) is replaced, not stacked. */
internal fun NavBackStack<NavKey>.openSettingsDetail(key: NavKey) {
    when (lastOrNull()) {
        key -> Unit
        is SettingsChoiceKey, ImportKey, ExportKey -> this[lastIndex] = key
        else -> add(key)
    }
}

/**
 * Opens the articles of tag [name]. In two-pane mode they replace a tag already open beside the
 * Tags list (and any reader on top of it); on a phone they stack.
 */
internal fun NavBackStack<NavKey>.openTag(name: String, twoPane: Boolean) {
    if (twoPane) {
        val tags = indexOfLast { it == TagsKey }
        if (tags >= 0) subList(tags + 1, size).clear()
    }
    add(TagItemsKey(name))
}

/**
 * Opens search from [tab]. In two-pane mode an article open beside the list is closed first, so the
 * results don't pair with a reader that wasn't opened from them.
 */
internal fun NavBackStack<NavKey>.openSearch(tab: LibraryTab, twoPane: Boolean, fromTags: Boolean = false) {
    if (twoPane) while (lastOrNull() is ReaderKey) removeLastOrNull()
    add(SearchKey(tab, fromTags))
}

/** Opens [itemId] in the reader; a reader already on top is replaced rather than stacked. */
internal fun NavBackStack<NavKey>.openReader(itemId: String) {
    val key = ReaderKey(itemId)
    when (lastOrNull()) {
        key -> Unit
        is ReaderKey -> this[lastIndex] = key
        else -> add(key)
    }
}

/**
 * Switches tab. My List always stays at the bottom so Back from another tab returns to it, the
 * Android convention for the start destination.
 */
internal fun NavBackStack<NavKey>.navigateToTopLevel(destination: TopLevelDestination) {
    val target = buildList {
        add(TopLevelDestination.MY_LIST.key)
        if (destination != TopLevelDestination.MY_LIST) add(destination.key)
    }
    if (toList() != target) replaceAll(*target.toTypedArray())
}

/** Replaces the whole stack atomically (never observed empty). */
private fun NavBackStack<NavKey>.replaceAll(vararg keys: NavKey) {
    Snapshot.withMutableSnapshot {
        clear()
        addAll(keys)
    }
}
