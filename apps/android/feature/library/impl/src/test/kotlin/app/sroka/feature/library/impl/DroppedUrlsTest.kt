package app.sroka.feature.library.impl

import app.sroka.feature.library.impl.list.DroppedItem
import app.sroka.feature.library.impl.list.extractDroppedUrls
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DroppedUrlsTest {
    @Test
    fun textWithUrl() {
        assertEquals(
            listOf("https://example.com/a"),
            extractDroppedUrls(listOf(DroppedItem(text = "Read https://example.com/a now"))),
        )
    }

    @Test
    fun uriListWithSeveralLines() {
        val text = "# comment\nhttps://a.example/1\r\nhttps://b.example/2\n"
        assertEquals(
            listOf("https://a.example/1", "https://b.example/2"),
            extractDroppedUrls(listOf(DroppedItem(text = text))),
        )
    }

    @Test
    fun htmlHref() {
        val html = """<p><a class="x" href="https://example.com/h?a=1">link</a> <a href='https://other.example'>2</a></p>"""
        assertEquals(listOf("https://example.com/h?a=1"), extractDroppedUrls(listOf(DroppedItem(html = html))))
    }

    @Test
    fun junkYieldsNothing() {
        val items = listOf(DroppedItem(text = "no link here"), DroppedItem(), DroppedItem(html = "<b>x</b>"))
        assertTrue(extractDroppedUrls(items).isEmpty())
    }

    @Test
    fun nonHttpUrisIgnoredAndDuplicatesMerged() {
        val items = listOf(
            DroppedItem(uri = "content://x/1"),
            DroppedItem(uri = "file:///sdcard/a.html"),
            DroppedItem(uri = "https://example.com/a", text = "https://example.com/a"),
            DroppedItem(text = "https://example.com/a"),
        )
        assertEquals(listOf("https://example.com/a"), extractDroppedUrls(items))
    }
}
