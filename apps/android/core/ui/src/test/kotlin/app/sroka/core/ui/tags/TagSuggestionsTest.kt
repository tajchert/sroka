package app.sroka.core.ui.tags

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TagSuggestionsTest {
    @Test
    fun createChipOnlyWithoutExactCaseInsensitiveMatch() {
        val known = listOf("Weekend", "week", "essays")
        assertEquals("wee", tagSuggestions("wee", emptyList(), known).create)
        assertNull(tagSuggestions("WEEKEND", emptyList(), known).create)
        assertNull(tagSuggestions("  week ", emptyList(), known).create)
        assertNull(tagSuggestions("", emptyList(), known).create)
        assertNull(tagSuggestions("new", listOf("New"), known).create)
    }

    @Test
    fun existingSuggestionsMatchAndSkipChosen() {
        val known = listOf("Weekend", "week", "essays", "tweet")
        val s = tagSuggestions("wee", listOf("week"), known)
        assertEquals(listOf("Weekend", "tweet"), s.existing)
        assertEquals(listOf("Weekend", "week", "essays", "tweet"), tagSuggestions("", emptyList(), known).existing)
    }
}
