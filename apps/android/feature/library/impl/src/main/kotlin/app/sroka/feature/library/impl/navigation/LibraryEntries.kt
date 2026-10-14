package app.sroka.feature.library.impl.navigation

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.navigation3.runtime.EntryProviderScope
import androidx.navigation3.runtime.NavKey
import app.sroka.core.model.LibraryTab
import app.sroka.feature.library.api.LibraryKey
import app.sroka.feature.library.api.TagItemsKey
import app.sroka.feature.library.api.TagsKey
import app.sroka.feature.library.impl.R

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
 */
fun EntryProviderScope<NavKey>.libraryEntries(
    onOpenItem: (itemId: String) -> Unit,
    onOpenTag: (name: String) -> Unit,
    onOpenSettings: () -> Unit,
    onBack: () -> Unit,
) {
    entry<LibraryKey> { key ->
        Placeholder(
            stringResource(
                when (key.tab) {
                    LibraryTab.MY_LIST -> R.string.feature_library_my_list
                    LibraryTab.ARCHIVE -> R.string.feature_library_archive
                    LibraryTab.FAVORITES -> R.string.feature_library_favorites
                },
            ),
        )
    }
    entry<TagsKey> {
        Placeholder(stringResource(R.string.feature_library_tags))
    }
    entry<TagItemsKey> { key ->
        Placeholder(key.name)
    }
}

/** Placeholder until the library feature is implemented. */
@androidx.compose.runtime.Composable
private fun Placeholder(text: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(text)
    }
}
