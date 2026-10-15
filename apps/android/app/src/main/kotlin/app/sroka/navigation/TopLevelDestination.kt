package app.sroka.navigation

import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Label
import androidx.compose.material.icons.automirrored.outlined.Label
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Bookmarks
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.Bookmarks
import androidx.compose.material.icons.outlined.FavoriteBorder
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
    MY_LIST(LibraryKey(LibraryTab.MY_LIST), R.string.nav_my_list, Icons.Filled.Bookmarks, Icons.Outlined.Bookmarks),
    ARCHIVE(LibraryKey(LibraryTab.ARCHIVE), R.string.nav_archive, Icons.Filled.Archive, Icons.Outlined.Archive),
    FAVORITES(LibraryKey(LibraryTab.FAVORITES), R.string.nav_favorites, Icons.Filled.Favorite, Icons.Outlined.FavoriteBorder),
    TAGS(TagsKey, R.string.nav_tags, Icons.AutoMirrored.Filled.Label, Icons.AutoMirrored.Outlined.Label),
    ;

    companion object {
        /** The tab whose root is [key], or null for non-top-level keys (reader, settings, …). */
        fun of(key: NavKey?): TopLevelDestination? = entries.firstOrNull { it.key == key }
    }
}
