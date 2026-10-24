package app.sroka

import androidx.navigation3.runtime.NavKey
import app.sroka.core.model.LibraryTab
import app.sroka.feature.library.api.LibraryKey
import app.sroka.feature.library.api.SearchKey
import app.sroka.feature.library.api.TagItemsKey
import app.sroka.feature.reader.api.ReaderKey
import app.sroka.navigation.TopLevelDestination
import app.sroka.navigation.detailPaneItemId
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
    fun readerOverSearchIsNotBesideAList() {
        assertNull(detailPaneItemId(listOf(root, SearchKey(LibraryTab.MY_LIST), ReaderKey("a")), twoPane = true))
    }
}
