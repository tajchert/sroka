package app.sroka.navigation

import org.junit.Assert.assertEquals
import org.junit.Test

class PaneExpansionLogicTest {
    @Test
    fun restoreReturnsThePreviousAnchor() {
        assertEquals(3, restoreIndex(previous = 3, anchorCount = 5))
    }

    @Test
    fun restoreFallsBackTo360WhenPreviousIsCollapsedOrInvalid() {
        assertEquals(DEFAULT_LIST_INDEX, restoreIndex(COLLAPSED_INDEX, 5))
        assertEquals(DEFAULT_LIST_INDEX, restoreIndex(-1, 5))
        assertEquals(DEFAULT_LIST_INDEX, restoreIndex(9, 5))
    }

    @Test
    fun collapsedKeepsTheRememberedIndex() {
        assertEquals(3, rememberedIndex(current = COLLAPSED_INDEX, previous = 3))
        assertEquals(1, rememberedIndex(current = 1, previous = 3))
        assertEquals(3, rememberedIndex(current = -1, previous = 3))
    }
}
