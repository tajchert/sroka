package app.sroka.feature.library.impl.navigation

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.navigation3.ListDetailSceneStrategy
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.navigation3.runtime.EntryProviderScope
import androidx.navigation3.runtime.NavKey
import app.sroka.core.designsystem.component.DetailPaneCard
import app.sroka.core.model.LibraryTab
import app.sroka.feature.library.api.LibraryKey
import app.sroka.feature.library.impl.R
import app.sroka.feature.library.api.SearchKey
import app.sroka.feature.library.api.TagItemsKey
import app.sroka.feature.library.api.TagsKey
import app.sroka.feature.library.impl.list.LibraryListRoute
import app.sroka.feature.library.impl.list.ListScope
import app.sroka.feature.library.impl.search.SearchRoute
import app.sroka.feature.library.impl.tags.TagsRoute

/**
 * Library entries: the three list tabs, the Tags tab and per-tag lists.
 *
 * Features never reference other features' keys (DECISIONS A2), so cross-feature navigation goes
 * through callbacks that the app maps to keys.
 *
 * @param onOpenItem open the reader for an item id
 * @param onOpenTag open the list of items with a tag
 * @param onOpenSettings open settings
 * @param onCloseTag close the given tag list (and any reader opened from it)
 * @param onOpenSearch open the full-screen search, starting from the given tab
 * @param onCloseSearch leave the search screen
 * @param onSignIn the "sign in again" banner action; the app navigates to auth
 * @param selectedItemId the article open in the detail pane, or null (read lazily; two-pane highlight)
 * @param twoPane the list is the left pane of the list-detail layout
 * @param navRailShown the navigation rail hosts the save-link FAB and avatar, so lists hide theirs
 * @param addLinkRequested the rail's FAB was tapped; a list opens its add-link dialog and calls
 *   [onAddLinkHandled]
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
fun EntryProviderScope<NavKey>.libraryEntries(
    onOpenItem: (itemId: String) -> Unit,
    onOpenTag: (name: String) -> Unit,
    onOpenSettings: () -> Unit,
    onCloseTag: (TagItemsKey) -> Unit,
    onSignIn: () -> Unit = {},
    onOpenSearch: (LibraryTab) -> Unit = {},
    onCloseSearch: () -> Unit = {},
    selectedItemId: () -> String? = { null },
    twoPane: Boolean = false,
    navRailShown: Boolean = false,
    addLinkRequested: Boolean = false,
    onAddLinkHandled: () -> Unit = {},
) {
    // List pane: on wide windows the reader opens next to the list (ListDetailSceneStrategy).
    entry<LibraryKey>(metadata = listPaneMetadata()) { key ->
        LibraryListRoute(
            scope = ListScope.Tab(key.tab),
            onOpenItem = onOpenItem,
            onSignIn = onSignIn,
            onOpenSettings = onOpenSettings,
            onOpenSearch = onOpenSearch,
            selectedItemId = selectedItemId(),
            twoPane = twoPane,
            navRailShown = navRailShown,
            addLinkRequested = addLinkRequested,
            onAddLinkHandled = onAddLinkHandled,
        )
    }
    entry<SearchKey> { key ->
        SearchRoute(initialTab = key.tab, onOpenItem = onOpenItem, onBack = onCloseSearch)
    }
    entry<TagsKey> {
        TagsRoute(onOpenTag = onOpenTag, onOpenSettings = onOpenSettings)
    }
    entry<TagItemsKey>(metadata = listPaneMetadata()) { key ->
        LibraryListRoute(
            scope = ListScope.Tag(key.name),
            onOpenItem = onOpenItem,
            onSignIn = onSignIn,
            onBack = { onCloseTag(key) },
            selectedItemId = selectedItemId(),
            twoPane = twoPane,
            navRailShown = navRailShown,
        )
    }
}

/** List pane role, 360dp wide by default (R13); the app's drag handle can resize it. */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
private fun listPaneMetadata() =
    ListDetailSceneStrategy.listPane(detailPlaceholder = { DetailPlaceholder() }) +
        ListDetailSceneStrategy.preferredPaneSize(width = 360.dp)

/** Fills the empty detail pane on wide windows until an article is opened. */
@Composable
fun DetailPlaceholder() {
    DetailPaneCard {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(
                text = stringResource(R.string.feature_library_select_article),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
