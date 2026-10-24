package app.sroka.core.network

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PdfDtoTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; coerceInputValues = true }

    @Test fun itemWithoutPdfFieldsIsArticle() {
        val item = json.decodeFromString<ItemDto>("""{"id":"a","url":"https://x.test/a"}""")
        assertEquals("article", item.kind)
        assertNull(item.fileName)
        assertNull(item.fileSize)
    }

    @Test fun itemWithPdfFields() {
        val item = json.decodeFromString<ItemDto>("""{"id":"a","url":"u","kind":"pdf","fileName":"p.pdf","fileSize":50331648}""")
        assertEquals("pdf", item.kind)
        assertEquals("p.pdf", item.fileName)
        assertEquals(50331648L, item.fileSize)
    }

    @Test fun nullFileFieldsAndUnknownKindDecode() {
        val item = json.decodeFromString<ItemDto>("""{"id":"a","url":"u","kind":"epub","fileName":null,"fileSize":null}""")
        assertEquals("epub", item.kind)
        assertNull(item.fileName)
    }

    @Test fun contentUrlsWithAndWithoutDocumentUrl() {
        val article = json.decodeFromString<ContentUrlsDto>("""{"articleUrl":"a","baseUrl":"b","packageUrl":"p","expiresAt":1,"documentUrl":null}""")
        assertNull(article.documentUrl)
        assertNull(json.decodeFromString<ContentUrlsDto>("""{"articleUrl":"a","baseUrl":"b","packageUrl":"p"}""").documentUrl)
        assertEquals("d", json.decodeFromString<ContentUrlsDto>("""{"articleUrl":"a","baseUrl":"b","packageUrl":"p","documentUrl":"d"}""").documentUrl)
    }

    @Test fun uploadResponse() {
        val r = json.decodeFromString<PdfUploadResponseDto>("""{"item":{"id":"a","url":"u","kind":"pdf"},"created":false}""")
        assertEquals(false, r.created)
        assertEquals("a", r.item.id)
    }
}
