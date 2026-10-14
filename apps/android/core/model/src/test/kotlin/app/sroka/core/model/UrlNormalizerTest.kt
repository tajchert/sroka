package app.sroka.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors packages/shared/src/url.test.ts. */
class UrlNormalizerTest {

    private val cases = listOf(
        "HTTPS://Example.COM/Path?b=2&a=1#frag" to "https://example.com/Path?a=1&b=2",
        "https://example.com:443/x" to "https://example.com/x",
        "http://example.com:80/x" to "http://example.com/x",
        "http://example.com:8080/x" to "http://example.com:8080/x",
        "https://example.com" to "https://example.com/",
        "https://example.com/post?utm_source=x&utm_Medium=y&id=5" to "https://example.com/post?id=5",
        "https://example.com/?fbclid=1&gclid=2&dclid=3&msclkid=4&mc_eid=5&mc_cid=6&igshid=7&ref_src=8&_hsenc=9&_hsmktg=10&yclid=11" to "https://example.com/",
        "https://example.com/a/" to "https://example.com/a/",
        "https://www.example.com/a" to "https://www.example.com/a",
        "https://user:pw@example.com/a" to "https://example.com/a",
        "https://example.com./a" to "https://example.com/a",
        "https://example.com/a?z=1&a=2&z=0" to "https://example.com/a?a=2&z=1&z=0",
        "  https://example.com/a  " to "https://example.com/a",
        "https://bücher.de/" to "https://xn--bcher-kva.de/",
        "https://example.com/a?q=hello world" to "https://example.com/a?q=hello+world",
        // api.md §13 example
        "HTTPS://Example.COM:443/Path?utm_source=x&b=2&a=1#top" to "https://example.com/Path?a=1&b=2",
    )

    @Test
    fun normalizesSharedCases() {
        for ((input, expected) in cases) assertEquals(input, expected, UrlNormalizer.normalize(input))
    }

    @Test
    fun isIdempotent() {
        for ((_, out) in cases) assertEquals(out, UrlNormalizer.normalize(out))
    }

    @Test
    fun rejectsNonHttp() {
        assertNull(UrlNormalizer.normalize("ftp://x.com/"))
        assertNull(UrlNormalizer.normalize("javascript:alert(1)"))
        assertNull(UrlNormalizer.normalize("not a url"))
        assertNull(UrlNormalizer.normalize("https://"))
    }

    @Test
    fun isHttpUrl() {
        assertTrue(UrlNormalizer.isHttpUrl("https://a.b"))
        assertFalse(UrlNormalizer.isHttpUrl("mailto:a@b.c"))
        assertFalse(UrlNormalizer.isHttpUrl("/relative"))
    }

    @Test
    fun extractFirstUrlFindsUrlInShareText() {
        assertEquals("https://example.com/a?b=1", extractFirstUrl("Great read https://example.com/a?b=1 via @app"))
    }

    @Test
    fun extractFirstUrlStripsTrailingPunctuationAndUnbalancedParens() {
        assertEquals("https://example.com/x", extractFirstUrl("(see https://example.com/x)."))
        assertEquals("https://en.wikipedia.org/wiki/Foo_(bar)", extractFirstUrl("https://en.wikipedia.org/wiki/Foo_(bar)"))
        assertEquals("https://example.com/q", extractFirstUrl("\"https://example.com/q\"!"))
    }

    @Test
    fun extractFirstUrlReturnsNullWhenAbsent() {
        assertNull(extractFirstUrl("no links here"))
    }

    @Test
    fun displayDomainDropsWww() {
        assertEquals("example.com", displayDomain("https://www.Example.com/a"))
        assertEquals("", displayDomain("nope"))
    }
}
