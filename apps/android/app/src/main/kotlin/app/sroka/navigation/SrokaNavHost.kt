package app.sroka.navigation

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.Icon
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfoV2
import androidx.compose.material3.adaptive.layout.PaneScaffoldDirective
import androidx.compose.material3.adaptive.layout.calculatePaneScaffoldDirective
import androidx.compose.material3.adaptive.navigation3.rememberListDetailSceneStrategy
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffoldDefaults
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteType
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
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
import app.sroka.feature.auth.api.AuthKey
import app.sroka.feature.auth.impl.navigation.authEntries
import app.sroka.feature.library.api.TagItemsKey
import app.sroka.feature.library.impl.navigation.libraryEntries
import app.sroka.feature.reader.api.ReaderKey
import app.sroka.feature.reader.impl.navigation.readerEntries
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
    val directive = remember(windowAdaptiveInfo) {
        calculatePaneScaffoldDirective(windowAdaptiveInfo).copy(horizontalPartitionSpacerSize = 0.dp)
    }
    val twoPane = directive.maxHorizontalPartitions > 1
    val top = backStack.lastOrNull()
    val current = TopLevelDestination.of(top)
        ?: if (twoPane && top is ReaderKey) TopLevelDestination.of(backStack.getOrNull(backStack.size - 2)) else null
    val adaptiveType = NavigationSuiteScaffoldDefaults.calculateFromAdaptiveInfo(windowAdaptiveInfo)

    NavigationSuiteScaffold(
        modifier = modifier,
        layoutType = if (current != null) adaptiveType else NavigationSuiteType.None,
        navigationSuiteItems = {
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
                )
            }
        },
    ) {
        Box(Modifier.fillMaxSize()) {
            SrokaNavDisplay(backStack, directive, onArchived)
            // App-level snackbar for results that outlive a screen (archive from the reader).
            // On tab roots it sits above the list's FAB, like a Scaffold snackbar would.
            SnackbarHost(
                hostState = snackbarHostState,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .windowInsetsPadding(WindowInsets.navigationBars)
                    .padding(bottom = if (current != null) FabClearance else 0.dp),
            )
        }
    }
}

/** FAB height (56dp) plus its two 16dp margins. */
private val FabClearance = 88.dp

@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
private fun SrokaNavDisplay(
    backStack: NavBackStack<NavKey>,
    directive: PaneScaffoldDirective,
    onArchived: (itemId: String) -> Unit,
) {
    val listDetailStrategy = rememberListDetailSceneStrategy<NavKey>(directive = directive)
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
                onOpenItem = { itemId ->
                    val key = ReaderKey(itemId)
                    when (backStack.lastOrNull()) {
                        key -> Unit
                        is ReaderKey -> backStack[backStack.lastIndex] = key
                        else -> backStack.add(key)
                    }
                },
                onOpenTag = { name -> backStack.add(TagItemsKey(name)) },
                onOpenSettings = { backStack.add(SettingsKey) },
                onCloseTag = { key ->
                    val i = backStack.lastIndexOf(key)
                    if (i > 0) backStack.subList(i, backStack.size).clear()
                },
                // From the Expired banner: sign in on top of the library; success pops it.
                onSignIn = { if (backStack.lastOrNull() != AuthKey) backStack.add(AuthKey) },
            )
            readerEntries(onBack = goBack, onArchived = onArchived)
            settingsEntries(onBack = goBack)
        },
    )
}

/**
 * Switches tab. My List always stays at the bottom so Back from another tab returns to it, the
 * Android convention for the start destination.
 */
private fun NavBackStack<NavKey>.navigateToTopLevel(destination: TopLevelDestination) {
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
