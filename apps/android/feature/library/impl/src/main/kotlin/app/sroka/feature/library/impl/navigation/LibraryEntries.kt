package app.sroka.feature.library.impl.navigation

import androidx.compose.runtime.Composable
import app.sroka.core.designsystem.component.DetailPaneCard
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.navigation3.ListDetailSceneStrategy
import androidx.compose.ui.unit.dp
import androidx.navigation3.runtime.EntryProviderScope
import androidx.navigation3.runtime.NavKey
import app.sroka.core.model.LibraryTab
import app.sroka.core.ui.adaptive.LocalPaneLayout
import app.sroka.feature.library.api.LibraryKey
import app.sroka.feature.library.api.SearchKey
import app.sroka.feature.library.api.TagItemsKey
import app.sroka.feature.library.api.TagsKey
import app.sroka.feature.library.impl.detail.DetailPlaceholder
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
 * @param onCloseSearch leave the search screen (and any reader opened from it)
 * @param selectedTag the tag open in the detail pane, or null (two-pane highlight in the Tags list)
 * @param onSignIn the "sign in again" banner action; the app navigates to auth
 * @param selectedItemId the article open in the detail pane, or null (read lazily; two-pane highlight)
 * @param addLinkRequested the rail's FAB was tapped (read lazily); a list opens its add-link dialog and
 *   calls [onAddLinkHandled]
 *
 * Two-pane / rail state is read live from [LocalPaneLayout] (entry content outlives window changes).
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
fun EntryProviderScope<NavKey>.libraryEntries(
    onOpenItem: (itemId: String) -> Unit,
    onOpenTag: (name: String) -> Unit,
    onOpenSettings: () -> Unit,
    onCloseTag: (TagItemsKey) -> Unit,
    onSignIn: () -> Unit = {},
    onOpenSearch: (LibraryTab) -> Unit = {},
    onOpenTagsSearch: () -> Unit = {},
    onCloseSearch: (SearchKey) -> Unit = {},
    selectedTag: () -> String? = { null },
    selectedItemId: () -> String? = { null },
    addLinkRequested: () -> Boolean = { false },
    onAddLinkHandled: () -> Unit = {},
) {
    // List pane: on wide windows the reader opens next to the list (ListDetailSceneStrategy).
    entry<LibraryKey>(metadata = listPaneMetadata(onOpenItem)) { key ->
        val layout = LocalPaneLayout.current
        LibraryListRoute(
            scope = ListScope.Tab(key.tab),
            onOpenItem = onOpenItem,
            onSignIn = onSignIn,
            onOpenSettings = onOpenSettings,
            onOpenSearch = onOpenSearch,
            selectedItemId = selectedItemId(),
            twoPane = layout.twoPane,
            navRailShown = layout.railShown,
            addLinkRequested = addLinkRequested(),
            onAddLinkHandled = onAddLinkHandled,
        )
    }
    entry<SearchKey>(metadata = listPaneMetadata(onOpenItem)) { key ->
        val layout = LocalPaneLayout.current
        SearchRoute(
            // From Tags the scope is All (the default tab filter), whatever the key's tab says.
            initialTab = key.tab,
            onOpenItem = onOpenItem,
            onBack = { onCloseSearch(key) },
            selectedItemId = selectedItemId(),
            twoPane = layout.twoPane,
        )
    }
    entry<TagsKey>(metadata = listPaneMetadata(onOpenItem)) {
        val layout = LocalPaneLayout.current
        TagsRoute(
            onOpenTag = onOpenTag,
            onOpenSettings = onOpenSettings,
            onOpenSearch = onOpenTagsSearch,
            selectedTag = selectedTag(),
            navRailShown = layout.railShown,
        )
    }
    // Detail pane on wide windows (the opened article covers it); no back arrow beside the tag list.
    entry<TagItemsKey>(metadata = ListDetailSceneStrategy.detailPane()) { key ->
        val layout = LocalPaneLayout.current
        val list = @Composable {
            LibraryListRoute(
                scope = ListScope.Tag(key.name),
                onOpenItem = onOpenItem,
                onSignIn = onSignIn,
                onBack = if (layout.twoPane) null else ({ onCloseTag(key) }),
                selectedItemId = selectedItemId(),
                twoPane = layout.twoPane,
                navRailShown = layout.railShown,
                detailCard = layout.twoPane,
            )
        }
        // Beside the tag list the articles sit in the detail card, like the reader (R14.5).
        if (layout.twoPane) DetailPaneCard { list() } else list()
    }
}

/** List pane role, 360dp wide by default (R13); the app's drag handle can resize it. */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
private fun listPaneMetadata(onOpenItem: (String) -> Unit) =
    ListDetailSceneStrategy.listPane(detailPlaceholder = { DetailPlaceholder(onOpenItem) }) +
        ListDetailSceneStrategy.preferredPaneSize(width = 360.dp)
