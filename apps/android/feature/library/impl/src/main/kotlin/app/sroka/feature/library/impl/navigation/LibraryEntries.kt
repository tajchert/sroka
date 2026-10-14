package app.sroka.feature.library.impl.navigation

import androidx.navigation3.runtime.EntryProviderScope
import androidx.navigation3.runtime.NavKey
import app.sroka.feature.library.api.LibraryKey
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
fun EntryProviderScope<NavKey>.libraryEntries(
    onOpenItem: (itemId: String) -> Unit,
    onOpenTag: (name: String) -> Unit,
    onOpenSettings: () -> Unit,
    onBack: () -> Unit,
    onSignIn: () -> Unit = {},
) {
    entry<LibraryKey> { key ->
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
    entry<TagItemsKey> { key ->
        LibraryListRoute(
            scope = ListScope.Tag(key.name),
            onOpenItem = onOpenItem,
            onSignIn = onSignIn,
            onBack = onBack,
        )
    }
}
