package app.sroka.navigation

import androidx.navigation3.runtime.NavKey
import app.sroka.feature.library.api.LibraryKey
import app.sroka.feature.library.api.TagItemsKey
import app.sroka.feature.reader.api.ReaderKey

/**
 * The article shown in the detail pane next to the list, or null. That is the case only in
 * two-pane mode with a [ReaderKey] on top of a list pane ([LibraryKey] or [TagItemsKey]); a reader
 * opened over the full-screen search is not beside a list.
 */
internal fun detailPaneItemId(backStack: List<NavKey>, twoPane: Boolean): String? {
    if (!twoPane) return null
    val top = backStack.lastOrNull() as? ReaderKey ?: return null
    val below = backStack.getOrNull(backStack.size - 2)
    return top.itemId.takeIf { below is LibraryKey || below is TagItemsKey }
}
