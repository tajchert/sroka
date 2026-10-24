package app.sroka

import androidx.navigation3.runtime.NavBackStack
import androidx.navigation3.runtime.NavKey
import app.sroka.core.model.LibraryTab
import app.sroka.feature.library.api.SearchKey
import app.sroka.feature.reader.api.ReaderKey
import app.sroka.navigation.TopLevelDestination
import app.sroka.navigation.openReader
import app.sroka.navigation.openSearch
import org.junit.Assert.assertEquals
import org.junit.Test

class OpenReaderTest {
    private val root = TopLevelDestination.MY_LIST.key

    @Test
    fun pushesReaderOnTopOfTheStack() {
        val stack = NavBackStack<NavKey>(root)
        stack.openReader("a")
        assertEquals(listOf(root, ReaderKey("a")), stack.toList())
    }

    @Test
    fun replacesAReaderAlreadyOnTop() {
        val stack = NavBackStack<NavKey>(root, ReaderKey("a"))
        stack.openReader("b")
        assertEquals(listOf(root, ReaderKey("b")), stack.toList())
        stack.openReader("b")
        assertEquals(2, stack.size)
    }

    @Test
    fun searchClosesTheOpenArticleOnlyInTwoPane() {
        val twoPane = NavBackStack<NavKey>(root, ReaderKey("a"))
        twoPane.openSearch(LibraryTab.MY_LIST, twoPane = true)
        assertEquals(listOf(root, SearchKey(LibraryTab.MY_LIST)), twoPane.toList())

        val phone = NavBackStack<NavKey>(root, ReaderKey("a"))
        phone.openSearch(LibraryTab.MY_LIST, twoPane = false)
        assertEquals(listOf(root, ReaderKey("a"), SearchKey(LibraryTab.MY_LIST)), phone.toList())
    }
}
