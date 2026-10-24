package app.sroka.navigation

import app.sroka.core.designsystem.icon.SrokaIcons
import androidx.annotation.StringRes
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.navigation3.runtime.NavKey
import app.sroka.R
import app.sroka.core.model.LibraryTab
import app.sroka.feature.library.api.LibraryKey
import app.sroka.feature.library.api.TagsKey

/** Tabs of the navigation bar/rail (DECISIONS A11). [MY_LIST] is the start destination. */
enum class TopLevelDestination(
    val key: NavKey,
    @StringRes val label: Int,
    val selectedIcon: ImageVector,
    val unselectedIcon: ImageVector,
) {
    // Rounded (filled) when selected, outlined otherwise: the icon set has no unfilled Rounded variants.
    MY_LIST(LibraryKey(LibraryTab.MY_LIST), R.string.nav_my_list, SrokaIcons.BookmarksFilled, SrokaIcons.Bookmarks),
    FAVORITES(LibraryKey(LibraryTab.FAVORITES), R.string.nav_favorites, SrokaIcons.StarFilled, SrokaIcons.Star),
    ARCHIVE(LibraryKey(LibraryTab.ARCHIVE), R.string.nav_archive, SrokaIcons.ArchiveFilled, SrokaIcons.Archive),
    TAGS(TagsKey, R.string.nav_tags, SrokaIcons.LabelFilled, SrokaIcons.Label),
    ;

    companion object {
        /** The tab whose root is [key], or null for non-top-level keys (reader, settings, …). */
        fun of(key: NavKey?): TopLevelDestination? = entries.firstOrNull { it.key == key }
    }
}
