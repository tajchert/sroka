package app.sroka.feature.library.api

import androidx.navigation3.runtime.NavKey
import app.sroka.core.model.LibraryTab
import kotlinx.serialization.Serializable

/** Top-level list tab: My List, Archive or Favorites. */
@Serializable
data class LibraryKey(val tab: LibraryTab = LibraryTab.MY_LIST) : NavKey

/** Top-level Tags tab: all tags with counts. */
@Serializable
data object TagsKey : NavKey

/** Items carrying the tag [name] (any status). */
@Serializable
data class TagItemsKey(val name: String) : NavKey

/** Full-screen search; [tab] picks the initial filter chip (Archive/Favourites tabs preselect theirs). */
@Serializable
data class SearchKey(val tab: LibraryTab = LibraryTab.MY_LIST) : NavKey
