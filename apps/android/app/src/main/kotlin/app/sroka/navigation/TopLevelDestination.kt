package app.sroka.navigation

import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Label
import androidx.compose.material.icons.automirrored.rounded.Label
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.Bookmarks
import androidx.compose.material.icons.outlined.StarBorder
import androidx.compose.material.icons.rounded.Archive
import androidx.compose.material.icons.rounded.Bookmarks
import androidx.compose.material.icons.rounded.Star
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
    MY_LIST(LibraryKey(LibraryTab.MY_LIST), R.string.nav_my_list, Icons.Rounded.Bookmarks, Icons.Outlined.Bookmarks),
    FAVORITES(LibraryKey(LibraryTab.FAVORITES), R.string.nav_favorites, Icons.Rounded.Star, Icons.Outlined.StarBorder),
    ARCHIVE(LibraryKey(LibraryTab.ARCHIVE), R.string.nav_archive, Icons.Rounded.Archive, Icons.Outlined.Archive),
    TAGS(TagsKey, R.string.nav_tags, Icons.AutoMirrored.Rounded.Label, Icons.AutoMirrored.Outlined.Label),
    ;

    companion object {
        /** The tab whose root is [key], or null for non-top-level keys (reader, settings, …). */
        fun of(key: NavKey?): TopLevelDestination? = entries.firstOrNull { it.key == key }
    }
}
