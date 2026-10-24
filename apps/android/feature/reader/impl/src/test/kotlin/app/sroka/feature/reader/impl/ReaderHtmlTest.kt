package app.sroka.feature.reader.impl

import app.sroka.core.model.ReaderTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReaderHtmlTest {

    private fun wrap(html: String, nonce: String = "abc123", anchor: Int? = null, progress: Float = 0f) =
        ReaderHtml.wrap(html, "https://appassets.androidplatform.net/articles/i1/", EffectiveTheme.SEPIA, 1.2f, anchor, progress, nonce)

    @Test
    fun fragmentGetsFullDocumentWithCsp() {
        val out = wrap("<p>Hello</p>")
        assertTrue(out.startsWith("<!doctype html>"))
        assertTrue(out.contains("<body><p>Hello</p></body>"))
        assertTrue(
            out.contains(
                "content=\"default-src 'none'; img-src https://appassets.androidplatform.net data:; " +
                    "style-src 'unsafe-inline'; script-src 'nonce-abc123'\"",
            ),
        )
        assertTrue(out.contains("<script nonce=\"abc123\">"))
        assertTrue(out.contains("<base href=\"https://appassets.androidplatform.net/articles/i1/\">"))
        assertTrue(out.contains("data-theme=\"sepia\""))
        assertTrue(out.contains("--scale:1.20"))
    }

    @Test
    fun existingHeadGetsOurCspFirst() {
        val out = wrap("<!doctype html><html lang=\"en\"><head><title>t</title></head><body><p>x</p></body></html>")
        val head = out.indexOf("<head>")
        assertTrue(out.indexOf("Content-Security-Policy") > head)
        assertTrue(out.indexOf("Content-Security-Policy") < out.indexOf("<title>"))
        assertEquals(1, Regex("Content-Security-Policy").findAll(out).count())
        assertTrue(out.contains("<html data-theme=\"sepia\""))
    }

    @Test
    fun htmlWithoutHeadGetsHead() {
        val out = wrap("<html><body><p>x</p></body></html>")
        assertTrue(out.contains("<head><meta charset=\"utf-8\">"))
        assertEquals(1, Regex("Content-Security-Policy").findAll(out).count())
    }

    @Test
    fun restorePointIsEmbedded() {
        assertTrue(wrap("<p>x</p>", anchor = 7, progress = 0.5f).contains("START_A=7,START_P=0.5000"))
        assertTrue(wrap("<p>x</p>").contains("START_A=null,START_P=0.0000"))
    }

    @Test
    fun scriptHasNoUnreplacedPlaceholders() {
        assertFalse(Regex("__[A-Z_]+__").containsMatchIn(wrap("<p>x</p>")))
    }

    @Test
    fun nonceIsAlphanumericAndFresh() {
        val a = ReaderHtml.newNonce()
        assertTrue(a.isNotEmpty() && a.all { it.isLetterOrDigit() })
        assertTrue(a != ReaderHtml.newNonce())
    }

    @Test
    fun themeResolution() {
        assertEquals(EffectiveTheme.DARK, resolveTheme(ReaderTheme.AUTO, true))
        assertEquals(EffectiveTheme.LIGHT, resolveTheme(ReaderTheme.AUTO, false))
        assertEquals(EffectiveTheme.SEPIA, resolveTheme(ReaderTheme.SEPIA, true))
    }

    @Test
    fun parsesProgressMessages() {
        assertEquals(ProgressReport(0.5321f, 12), parseProgressMessage("0.5321|12"))
        assertEquals(ProgressReport(0f, null), parseProgressMessage("0.0000|"))
        assertEquals(ProgressReport(1f, 3), parseProgressMessage("1.7|3"))
        assertNull(parseProgressMessage(null))
        assertNull(parseProgressMessage("garbage"))
        assertNull(parseProgressMessage("0.5|x"))
        assertNull(parseProgressMessage("NaN|1"))
    }

    @Test
    fun headerIsInjectedAtBodyStartAndEscaped() {
        val header = ReaderHeader("a.com", "T <b>", "5 min read \u00b7 ", 0.42f, "Only part")
        val out = ReaderHtml.wrap(
            "<html><head></head><body><p>x</p></body></html>",
            "https://appassets.androidplatform.net/articles/i1/", EffectiveTheme.DARK, 1f, null, 0f, "n1", header,
        )
        assertTrue(out.contains("<body><header class=\"sk-head\">"))
        assertTrue(out.contains("T &lt;b&gt;"))
        assertTrue(out.contains("<span id=\"sk-pct\">42%</span>"))
        assertTrue(out.contains("sk-warn"))
        assertFalse(wrap("<p>x</p>").contains("<header class"))
    }

    @Test
    fun headerScriptPassesEscapedJsonStringLiteral() {
        val nasty = "A \"quoted\" </script><b>x</b> \\ & line\nbreak"
        val js = ReaderHtml.headerScript(ReaderHeader(nasty, "T", "5 min read \u00b7 ", 0f, null))
        assertTrue(js.startsWith("window.__srokaSetHeader&&window.__srokaSetHeader(\""))
        assertTrue(js.endsWith("\");"))
        assertFalse(js.contains("</script>"))
        assertFalse(js.contains("<b>"))
        assertFalse(js.contains("\n"))
        assertTrue(ReaderHtml.jsonString(nasty).contains("\\u003c/script\\u003e"))
        // The page script writes values with textContent only.
        val page = ReaderHtml.wrap("<p>x</p>", theme = EffectiveTheme.LIGHT, textScale = 1f, startAnchor = null, startProgress = 0f)
        assertTrue(page.contains("window.__srokaSetHeader=function"))
        assertFalse(page.contains("innerHTML"))
    }
}

class ReaderPaneStyleTest {
    @Test
    fun paneStyleOverridesBackgroundAndWidensTheColumn() {
        val out = ReaderHtml.wrap(
            "<p>Hello</p>", "https://appassets.androidplatform.net/articles/i1/", EffectiveTheme.DARK, 1f, null, 0f,
            "abc123", pane = ReaderPaneStyle(0xFF1B1E23.toInt()),
        )
        org.junit.Assert.assertTrue(out.contains("html[data-theme]{--bg:#1b1e23}"))
        org.junit.Assert.assertTrue(out.contains("max-width:640px"))
        org.junit.Assert.assertTrue(out.contains("font-size:36px"))
        org.junit.Assert.assertTrue(out.contains("padding-left:48px"))
    }

    @Test
    fun narrowPaneKeepsPhoneTitleAndPadding() {
        assertEquals(ReaderPaneStyle(0xFF000000.toInt(), narrow = true), ReaderPaneStyle.forWidth(0xFF000000.toInt(), 479))
        assertEquals(ReaderPaneStyle(0xFF000000.toInt(), narrow = false), ReaderPaneStyle.forWidth(0xFF000000.toInt(), 480))
        val out = ReaderHtml.wrap(
            "<p>Hello</p>", "https://appassets.androidplatform.net/articles/i1/", EffectiveTheme.DARK, 1f, null, 0f,
            "abc123", pane = ReaderPaneStyle.forWidth(0xFF1B1E23.toInt(), 350),
        )
        org.junit.Assert.assertTrue(out.contains("font-size:28px"))
        org.junit.Assert.assertTrue(out.contains("padding-left:24px"))
        org.junit.Assert.assertFalse(out.contains("font-size:36px"))
    }

    @Test
    fun noPaneStyleLeavesTheThemeBackground() {
        val out = ReaderHtml.wrap(
            "<p>Hello</p>", "https://appassets.androidplatform.net/articles/i1/", EffectiveTheme.DARK, 1f, null, 0f, "abc123",
        )
        org.junit.Assert.assertFalse(out.contains("max-width:640px"))
    }
}
