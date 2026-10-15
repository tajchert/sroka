package app.sroka.core.model

import org.junit.Assert.assertEquals
import org.junit.Test

/** Mirrors the tagKey cases in packages/shared/src/contract.test.ts. */
class TagsTest {
    @Test
    fun tagKeyFoldsNonAsciiCase() {
        assertEquals(tagKey("żółw"), tagKey("  Żółw "))
        assertEquals("éte", tagKey("Éte"))
        assertEquals("machine learning", tagKey("Machine   Learning"))
    }

    @Test
    fun normalizeTagNameKeepsCasing() {
        assertEquals("Machine Learning", normalizeTagName("  Machine \t Learning "))
        // NFD "e + combining acute" becomes NFC "é"
        assertEquals("é", normalizeTagName("é"))
    }
}
