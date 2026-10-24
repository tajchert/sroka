package app.sroka.core.data

import app.sroka.core.data.upload.cleanPdfName
import org.junit.Assert.assertEquals
import org.junit.Test

class PdfNameTest {
    @Test
    fun unknownNameFallsBackToGenericNeverAnId() {
        assertEquals("document.pdf", cleanPdfName(null))
        assertEquals("document.pdf", cleanPdfName("  "))
    }

    @Test
    fun keepsDisplayNameAndStripsDirectories() {
        assertEquals("Report.pdf", cleanPdfName("a/b/Report.pdf"))
        assertEquals(255, cleanPdfName("x".repeat(400)).length)
    }
}
