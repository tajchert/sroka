package app.sroka

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class PdfShareIntentTest {
    private val a = Uri.parse("content://docs/a.pdf")
    private val b = Uri.parse("content://docs/b.pdf")

    @Test
    fun singlePdfShareIsRecognisedAndReadFromExtraStream() {
        val intent = Intent(Intent.ACTION_SEND).setType("application/pdf").putExtra(Intent.EXTRA_STREAM, a)
        assertTrue(isPdfShare(intent))
        assertEquals(listOf(a), sharedPdfUris(intent))
    }

    @Test
    fun multiplePdfShareReadsEveryUri() {
        val intent = Intent(Intent.ACTION_SEND_MULTIPLE).setType("application/pdf")
            .putParcelableArrayListExtra(Intent.EXTRA_STREAM, arrayListOf(a, b, a))
        assertTrue(isPdfShare(intent))
        assertEquals(listOf(a, b), sharedPdfUris(intent))
    }

    @Test
    fun clipDataIsTheFallback() {
        val intent = Intent(Intent.ACTION_SEND).setType("application/pdf")
        intent.clipData = ClipData.newRawUri("pdf", a)
        assertEquals(listOf(a), sharedPdfUris(intent))
    }

    @Test
    fun textSharesAreNotPdfShares() {
        val intent = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "https://example.com")
        assertFalse(isPdfShare(intent))
        assertEquals(emptyList<Uri>(), sharedPdfUris(intent))
    }
}
