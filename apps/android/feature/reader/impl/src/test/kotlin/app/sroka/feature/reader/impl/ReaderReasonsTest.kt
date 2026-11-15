package app.sroka.feature.reader.impl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReaderReasonsTest {
    @Test
    fun mapsServerCodesToPlainReasons() {
        listOf("bot_wall", "render_bot_wall").forEach { assertEquals(FailureReason.BOT_WALL, failureReason(it)) }
        assertEquals(FailureReason.PAYWALLED, failureReason("paywalled"))
        listOf("http_404", "http_410").forEach { assertEquals(FailureReason.GONE, failureReason(it)) }
        listOf("http_500", "http_403", "http_503", "timeout", "network", "too_many_redirects", "bad_redirect")
            .forEach { assertEquals(it, FailureReason.NO_RESPONSE, failureReason(it)) }
        listOf("too_large", "render_too_large", "pdf_too_large").forEach { assertEquals(FailureReason.TOO_LARGE, failureReason(it)) }
        assertEquals(FailureReason.NOT_ARTICLE, failureReason("not_html"))
    }

    @Test
    fun unknownCodesHaveNoReason() {
        assertNull(failureReason(null))
        assertNull(failureReason(""))
        assertNull(failureReason("extract_failed"))
        assertNull(failureReason("blocked_url"))
        assertNull(failureReason("HTTP"))
    }

    @Test
    fun codesAreMatchedLeniently() {
        assertEquals(FailureReason.GONE, failureReason(" HTTP_404 "))
        assertEquals(FailureReason.BOT_WALL, failureReason("Bot_Wall"))
    }

    @Test
    fun onlyPaywalledIsPreviewOnly() {
        assertTrue(isPreviewOnly("paywalled"))
        assertFalse(isPreviewOnly("partial_content"))
        assertFalse(isPreviewOnly(null))
    }
}
