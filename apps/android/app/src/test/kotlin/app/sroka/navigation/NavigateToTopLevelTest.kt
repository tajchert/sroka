package app.sroka.navigation

import androidx.navigation3.runtime.NavBackStack
import androidx.navigation3.runtime.NavKey
import app.sroka.feature.reader.api.ReaderKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NavigateToTopLevelTest {
    private val myList = TopLevelDestination.MY_LIST.key
    private val archive = TopLevelDestination.ARCHIVE.key

    @Test
    fun reselectingTheShowingTabChangesNothing() {
        val stack = NavBackStack<NavKey>(myList, archive)
        assertFalse(stack.navigateToTopLevel(TopLevelDestination.ARCHIVE))
        assertEquals(listOf(myList, archive), stack.toList())
    }

    @Test
    fun switchingTabsOrPoppingAReaderIsANavigation() {
        val stack = NavBackStack<NavKey>(myList)
        assertTrue(stack.navigateToTopLevel(TopLevelDestination.ARCHIVE))
        assertEquals(listOf(myList, archive), stack.toList())

        val withReader = NavBackStack<NavKey>(myList, ReaderKey("a"))
        assertTrue(withReader.navigateToTopLevel(TopLevelDestination.MY_LIST))
        assertEquals(listOf(myList), withReader.toList())
    }
}
