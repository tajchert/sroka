package app.sroka

import androidx.navigation3.runtime.NavBackStack
import androidx.navigation3.runtime.NavKey
import app.sroka.feature.reader.api.ReaderKey
import app.sroka.navigation.TopLevelDestination
import app.sroka.navigation.openReader
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
}
