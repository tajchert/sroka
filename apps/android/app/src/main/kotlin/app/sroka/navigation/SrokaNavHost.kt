package app.sroka.navigation

import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffoldDefaults
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteType
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.viewmodel.navigation3.rememberViewModelStoreNavEntryDecorator
import androidx.navigation3.runtime.NavBackStack
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.runtime.rememberSaveableStateHolderNavEntryDecorator
import androidx.navigation3.ui.NavDisplay
import app.sroka.feature.auth.api.AuthKey
import app.sroka.feature.auth.impl.navigation.authEntries
import app.sroka.feature.library.api.TagItemsKey
import app.sroka.feature.library.impl.navigation.libraryEntries
import app.sroka.feature.reader.api.ReaderKey
import app.sroka.feature.reader.impl.navigation.readerEntries
import app.sroka.feature.settings.api.SettingsKey
import app.sroka.feature.settings.impl.navigation.settingsEntries

/**
 * App shell: one Navigation 3 back stack plus a [NavigationSuiteScaffold] (bottom bar on phones,
 * rail on larger windows) for the top-level tabs (DECISIONS A11). The bar is shown only while a tab
 * root is on top; reader, settings, tag lists and sign-in are full screen.
 *
 * The session drives the stack: signed out ⇒ only [AuthKey]; signing in replaces it with My List.
 * Features never see each other's keys; their navigation callbacks are mapped to keys here.
 */
@Composable
fun SrokaApp(
    isSignedIn: Boolean,
    modifier: Modifier = Modifier,
) {
    val startKey = if (isSignedIn) TopLevelDestination.MY_LIST.key else AuthKey
    val backStack = rememberNavBackStack(startKey)

    LaunchedEffect(isSignedIn) {
        val showsAuth = backStack.contains(AuthKey)
        if (isSignedIn == showsAuth) backStack.replaceAll(if (isSignedIn) TopLevelDestination.MY_LIST.key else AuthKey)
    }

    val current = TopLevelDestination.of(backStack.lastOrNull())
    val adaptiveType = NavigationSuiteScaffoldDefaults.calculateFromAdaptiveInfo(currentWindowAdaptiveInfo())

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
        SrokaNavDisplay(backStack)
    }
}

@Composable
private fun SrokaNavDisplay(backStack: NavBackStack<NavKey>) {
    val goBack: () -> Unit = { if (backStack.size > 1) backStack.removeLastOrNull() }
    NavDisplay(
        backStack = backStack,
        onBack = goBack,
        // Specifying entryDecorators replaces the defaults, so the saveable-state
        // decorator is listed explicitly next to the per-entry ViewModel store.
        entryDecorators = listOf(
            rememberSaveableStateHolderNavEntryDecorator(),
            rememberViewModelStoreNavEntryDecorator(),
        ),
        entryProvider = entryProvider {
            authEntries()
            libraryEntries(
                onOpenItem = { itemId -> backStack.add(ReaderKey(itemId)) },
                onOpenTag = { name -> backStack.add(TagItemsKey(name)) },
                onOpenSettings = { backStack.add(SettingsKey) },
                onBack = goBack,
            )
            readerEntries(onBack = goBack)
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
