package app.sroka.core.database

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FtsQueryTest {
    @Test fun singleTermIsQuotedPrefix() = assertEquals("\"kotlin*\"", FtsQuery.build("kotlin"))

    @Test fun multipleTermsAreAnded() = assertEquals("\"red*\" \"fox*\"", FtsQuery.build("  red   fox "))

    @Test fun syntaxCharactersAreSeparators() {
        assertEquals("\"a*\" \"b*\"", FtsQuery.build("a\" * ( ) : ^ - b"))
        assertEquals("\"title*\" \"x*\"", FtsQuery.build("title:x*"))
    }

    @Test fun operatorsBecomeLiteralWords() =
        assertEquals("\"cats*\" \"OR*\" \"dogs*\" \"NOT*\" \"NEAR*\"", FtsQuery.build("cats OR dogs NOT NEAR"))

    @Test fun onlyPunctuationIsNull() {
        assertNull(FtsQuery.build("\"*()-:^"))
        assertNull(FtsQuery.build("   "))
    }

    @Test fun keepsUnicodeLettersAndCombiningMarks() {
        assertEquals("\"zażółć*\"", FtsQuery.build("zażółć"))
        assertEquals("\"café*\"", FtsQuery.build("café"))
    }

    @Test fun capsTermsAndLength() {
        assertEquals(FtsQuery.MAX_TERMS, FtsQuery.build((1..20).joinToString(" ") { "w$it" })!!.split(" ").size)
        assertEquals(FtsQuery.MAX_TERM_LENGTH + 3, FtsQuery.build("x".repeat(500))!!.length)
    }
}
