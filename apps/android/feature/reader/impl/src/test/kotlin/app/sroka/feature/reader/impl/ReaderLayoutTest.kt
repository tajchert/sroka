package app.sroka.feature.reader.impl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReaderLayoutTest {
    @Test
    fun halfOpenedHorizontalIsTabletop() {
        assertEquals(ReaderLayout.Tabletop(1000, 1040), readerLayoutFor(true, true, 1000, 1040, 2000))
    }

    @Test
    fun flatFoldedVerticalOrBadBoundsAreNormal() {
        assertEquals(ReaderLayout.Normal, readerLayoutFor(false, true, 1000, 1040, 2000))
        assertEquals(ReaderLayout.Normal, readerLayoutFor(true, false, 1000, 1040, 2000))
        assertEquals(ReaderLayout.Normal, readerLayoutFor(true, true, 0, 0, 2000))
        assertEquals(ReaderLayout.Normal, readerLayoutFor(true, true, 1040, 1000, 2000))
        assertEquals(ReaderLayout.Normal, readerLayoutFor(true, true, 1000, 2000, 2000))
    }

    @Test
    fun scrubAndLabels() {
        assertEquals(0f, scrubFraction(-1f), 0f)
        assertEquals(1f, scrubFraction(2f), 0f)
        assertEquals(0f, scrubFraction(Float.NaN), 0f)
        assertEquals(42, percentRead(0.42f))
        assertEquals(3, minutesLeft(6, 0.5f))
        assertEquals(0, minutesLeft(6, 1f))
        assertNull(minutesLeft(null, 0.5f))
        assertNull(minutesLeft(0, 0.5f))
    }

    @Test
    fun textStepper() {
        assertEquals(18, textSizePx(1.0f))
        assertEquals(1.1f, steppedTextScale(1.0f, 1), 0.001f)
        assertEquals(0.9f, steppedTextScale(1.0f, -1), 0.001f)
        assertEquals(0.8f, steppedTextScale(0.8f, -1), 0.001f)
        assertEquals(1.6f, steppedTextScale(1.6f, 1), 0.001f)
    }

    @Test
    fun scrollScriptClampsFraction() {
        assertTrue(ReaderHtml.scrollToFractionScript(0.42f).contains("(0.4200)"))
        assertTrue(ReaderHtml.scrollToFractionScript(3f).contains("(1.0000)"))
        assertTrue(ReaderHtml.scrollToFractionScript(Float.NaN).contains("(0.0000)"))
    }
}
