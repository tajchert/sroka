package app.sroka.navigation

import androidx.navigation3.runtime.NavKey
import app.sroka.feature.library.api.LibraryKey
import app.sroka.feature.library.api.SearchKey
import app.sroka.feature.library.api.TagItemsKey
import app.sroka.feature.library.api.TagsKey
import app.sroka.feature.reader.api.ReaderKey

/**
 * The article shown in the detail pane next to the list, or null. That is the case only in
 * two-pane mode with a [ReaderKey] on top of a list pane ([LibraryKey], [SearchKey]) or of a tag's
 * article list ([TagItemsKey], which is itself a detail pane that the reader then covers).
 */
internal fun detailPaneItemId(backStack: List<NavKey>, twoPane: Boolean): String? {
    if (!twoPane) return null
    val top = backStack.lastOrNull() as? ReaderKey ?: return null
    val below = backStack.getOrNull(backStack.size - 2)
    return top.itemId.takeIf { below is LibraryKey || below is TagItemsKey || below is SearchKey }
}

/** The tag whose articles are shown in the detail pane (also while a reader covers them), or null. */
internal fun selectedTagName(backStack: List<NavKey>, twoPane: Boolean): String? {
    if (!twoPane) return null
    val top = backStack.lastOrNull()
    val key = if (top is ReaderKey) backStack.getOrNull(backStack.size - 2) else top
    return (key as? TagItemsKey)?.name
}

/**
 * The tab the rail/bar highlights. A tab root is its own tab. In two-pane mode the screens that sit
 * beside a tab's list keep that tab: a reader (over the tab, a search or a tag), a search (the tab it
 * was opened from) and a tag's articles (Tags). Otherwise null (bar hidden, full screen).
 */
internal fun currentTab(backStack: List<NavKey>, twoPane: Boolean): TopLevelDestination? {
    TopLevelDestination.of(backStack.lastOrNull())?.let { return it }
    if (!twoPane) return null
    var i = backStack.lastIndex
    if (backStack.getOrNull(i) is ReaderKey) i--
    return when (val key = backStack.getOrNull(i)) {
        is SearchKey -> if (key.fromTags) TopLevelDestination.TAGS else TopLevelDestination.of(LibraryKey(key.tab))
        is TagItemsKey -> TopLevelDestination.TAGS
        is LibraryKey, is TagsKey -> TopLevelDestination.of(key)
        else -> null
    }
}
