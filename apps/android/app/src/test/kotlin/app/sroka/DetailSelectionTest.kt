package app.sroka

import androidx.navigation3.runtime.NavKey
import app.sroka.core.model.LibraryTab
import app.sroka.feature.library.api.LibraryKey
import app.sroka.feature.library.api.SearchKey
import app.sroka.feature.library.api.TagItemsKey
import app.sroka.feature.library.api.TagsKey
import app.sroka.feature.reader.api.ReaderKey
import app.sroka.navigation.TopLevelDestination
import app.sroka.navigation.currentTab
import app.sroka.navigation.detailPaneItemId
import app.sroka.navigation.selectedTagName
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DetailSelectionTest {
    private val root: NavKey = TopLevelDestination.MY_LIST.key

    @Test
    fun readerOverListIsSelectedInTwoPane() {
        assertEquals("a", detailPaneItemId(listOf(root, ReaderKey("a")), twoPane = true))
    }

    @Test
    fun readerOverTagListIsSelected() {
        assertEquals("a", detailPaneItemId(listOf(root, TagItemsKey("x"), ReaderKey("a")), twoPane = true))
    }

    @Test
    fun nothingSelectedOnPhone() {
        assertNull(detailPaneItemId(listOf(root, ReaderKey("a")), twoPane = false))
    }

    @Test
    fun nothingSelectedWithoutReaderOnTop() {
        assertNull(detailPaneItemId(listOf(root), twoPane = true))
        assertNull(detailPaneItemId(emptyList(), twoPane = true))
    }

    @Test
    fun readerOverSearchIsSelectedInTwoPaneOnly() {
        val stack = listOf(root, SearchKey(LibraryTab.MY_LIST), ReaderKey("a"))
        assertEquals("a", detailPaneItemId(stack, twoPane = true))
        assertNull(detailPaneItemId(stack, twoPane = false))
    }

    @Test
    fun selectedTagFollowsTagItemsWithOrWithoutReader() {
        val tags = listOf(root, TagsKey, TagItemsKey("x"))
        assertEquals("x", selectedTagName(tags, twoPane = true))
        assertEquals("x", selectedTagName(tags + ReaderKey("a"), twoPane = true))
        assertNull(selectedTagName(tags, twoPane = false))
        assertNull(selectedTagName(listOf(root, TagsKey), twoPane = true))
    }

    @Test
    fun currentTabKeepsTheTabBesideTheList() {
        val search = SearchKey(LibraryTab.ARCHIVE)
        assertEquals(TopLevelDestination.ARCHIVE, currentTab(listOf(root, search), twoPane = true))
        assertEquals(TopLevelDestination.ARCHIVE, currentTab(listOf(root, search, ReaderKey("a")), twoPane = true))
        assertEquals(TopLevelDestination.TAGS, currentTab(listOf(root, TagsKey, TagItemsKey("x")), twoPane = true))
        assertEquals(TopLevelDestination.TAGS, currentTab(listOf(root, TagsKey, TagItemsKey("x"), ReaderKey("a")), twoPane = true))
        assertEquals(TopLevelDestination.MY_LIST, currentTab(listOf(root, ReaderKey("a")), twoPane = true))
        assertEquals(TopLevelDestination.TAGS, currentTab(listOf(root, TagsKey), twoPane = false))
        val tagsSearch = SearchKey(fromTags = true)
        assertEquals(TopLevelDestination.TAGS, currentTab(listOf(root, TagsKey, tagsSearch), twoPane = true))
        assertEquals(TopLevelDestination.TAGS, currentTab(listOf(root, TagsKey, tagsSearch, ReaderKey("a")), twoPane = true))
    }

    @Test
    fun currentTabIsNullFullScreenOnPhone() {
        assertNull(currentTab(listOf(root, SearchKey()), twoPane = false))
        assertNull(currentTab(listOf(root, TagsKey, TagItemsKey("x")), twoPane = false))
        assertNull(currentTab(listOf(root, ReaderKey("a")), twoPane = false))
    }
}
