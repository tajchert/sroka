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
import androidx.navigation3.runtime.EntryProviderScope
import androidx.navigation3.runtime.NavKey
import app.sroka.feature.library.api.LibraryKey
import app.sroka.feature.library.impl.R
import app.sroka.feature.library.api.TagItemsKey
import app.sroka.feature.library.api.TagsKey
import app.sroka.feature.library.impl.list.LibraryListRoute
import app.sroka.feature.library.impl.list.ListScope
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
 * @param onBack pop the current entry (tag item list)
 * @param onSignIn the "sign in again" banner action; the app navigates to auth
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
fun EntryProviderScope<NavKey>.libraryEntries(
    onOpenItem: (itemId: String) -> Unit,
    onOpenTag: (name: String) -> Unit,
    onOpenSettings: () -> Unit,
    onBack: () -> Unit,
    onSignIn: () -> Unit = {},
) {
    // List pane: on wide windows the reader opens next to the list (ListDetailSceneStrategy).
    entry<LibraryKey>(metadata = ListDetailSceneStrategy.listPane(detailPlaceholder = { DetailPlaceholder() })) { key ->
        LibraryListRoute(
            scope = ListScope.Tab(key.tab),
            onOpenItem = onOpenItem,
            onSignIn = onSignIn,
            onOpenSettings = onOpenSettings,
        )
    }
    entry<TagsKey> {
        TagsRoute(onOpenTag = onOpenTag, onOpenSettings = onOpenSettings)
    }
    entry<TagItemsKey>(metadata = ListDetailSceneStrategy.listPane(detailPlaceholder = { DetailPlaceholder() })) { key ->
        LibraryListRoute(
            scope = ListScope.Tag(key.name),
            onOpenItem = onOpenItem,
            onSignIn = onSignIn,
            onBack = onBack,
        )
    }
}

/** Fills the empty detail pane on wide windows until an article is opened. */
@Composable
private fun DetailPlaceholder() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            text = stringResource(R.string.feature_library_select_article),
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
