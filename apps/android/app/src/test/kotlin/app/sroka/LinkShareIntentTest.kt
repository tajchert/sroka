package app.sroka

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class LinkShareIntentTest {
    @Test
    fun extraTextWins() {
        val intent = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "Read https://a.example/x")
        intent.clipData = ClipData.newPlainText("t", "https://b.example")
        assertEquals("Read https://a.example/x", sharedLinkText(intent))
    }

    @Test
    fun clipDataTextOrUriIsTheFallback() {
        val text = Intent(Intent.ACTION_SEND).setType("text/plain")
        text.clipData = ClipData.newPlainText("t", "https://b.example")
        assertEquals("https://b.example", sharedLinkText(text))

        val uri = Intent(Intent.ACTION_SEND).setType("text/x-uri")
        uri.clipData = ClipData.newRawUri("u", Uri.parse("https://c.example/p"))
        assertEquals("https://c.example/p", sharedLinkText(uri))
    }

    @Test
    fun dataUriIsTheLastResort() {
        assertEquals("https://d.example/", sharedLinkText(Intent(Intent.ACTION_SEND, Uri.parse("https://d.example/"))))
        assertNull(sharedLinkText(Intent(Intent.ACTION_SEND).setType("text/plain")))
    }
}
