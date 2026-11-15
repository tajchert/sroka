package app.sroka.feature.auth.impl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ClipboardCodeTest {
    @Test
    fun exactSixDigitsAreACode() {
        assertEquals("481920", parseClipboardCode("481920"))
        assertEquals("000123", parseClipboardCode("000123"))
    }

    @Test
    fun surroundingWhitespaceIsIgnored() {
        assertEquals("481920", parseClipboardCode("  481920\n"))
        assertEquals("481920", parseClipboardCode("\t481920 "))
    }

    @Test
    fun anythingElseIsNotACode() {
        assertNull(parseClipboardCode(null))
        assertNull(parseClipboardCode(""))
        assertNull(parseClipboardCode("48 19 20"))
        assertNull(parseClipboardCode("48-19-20"))
        assertNull(parseClipboardCode("4819201"))
        assertNull(parseClipboardCode("48192"))
        assertNull(parseClipboardCode("Your code is 481920"))
        assertNull(parseClipboardCode("481920 is the code"))
        assertNull(parseClipboardCode("48192a"))
        assertNull(parseClipboardCode("４８１９２０"))
    }
}
