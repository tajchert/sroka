package app.sroka.navigation

import app.sroka.core.designsystem.icon.SrokaIcons
import androidx.annotation.StringRes
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.navigation3.runtime.NavKey
import app.sroka.R
import app.sroka.core.model.LibraryTab
import app.sroka.feature.library.api.LibraryKey
import app.sroka.feature.library.api.TagsKey

/**
 * Top-level destinations (DECISIONS A11). Phones switch My List / Archive with the home chip row and
 * open Tags from its trailing chip; rail layouts list all three. [MY_LIST] is the start destination.
 * Favorites is a filter chip, not a destination (proposal 08).
 */
enum class TopLevelDestination(
    val key: NavKey,
    @StringRes val label: Int,
    val selectedIcon: ImageVector,
    val unselectedIcon: ImageVector,
) {
    // Rounded (filled) when selected, outlined otherwise: the icon set has no unfilled Rounded variants.
    MY_LIST(LibraryKey(LibraryTab.MY_LIST), R.string.nav_my_list, SrokaIcons.BookmarksFilled, SrokaIcons.Bookmarks),
    ARCHIVE(LibraryKey(LibraryTab.ARCHIVE), R.string.nav_archive, SrokaIcons.ArchiveFilled, SrokaIcons.Archive),
    TAGS(TagsKey, R.string.nav_tags, SrokaIcons.LabelFilled, SrokaIcons.Label),
    ;

    companion object {
        /** The tab whose root is [key], or null for non-top-level keys (reader, settings, …). */
        fun of(key: NavKey?): TopLevelDestination? = entries.firstOrNull { it.key == key }

        /** The destination showing list [tab]; Favorites is a filter of My List. */
        fun of(tab: LibraryTab): TopLevelDestination = if (tab == LibraryTab.ARCHIVE) ARCHIVE else MY_LIST
    }
}
