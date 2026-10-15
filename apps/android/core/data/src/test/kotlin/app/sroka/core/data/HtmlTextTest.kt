package app.sroka.core.data

import app.sroka.core.data.content.HtmlText
import org.junit.Assert.assertEquals
import org.junit.Test

class HtmlTextTest {
    @Test fun stripsTagsScriptsAndDecodesEntities() {
        val html = """<html><head><title>T</title><style>p{}</style></head><body><!-- c --><h1>Caf&eacute; &amp; tea</h1>
            <p>a&nbsp;b &#8212; &#x41;<script>alert(1)</script></p></body></html>"""
        assertEquals("Caf&eacute; & tea a b \u2014 A", HtmlText.extract(html))
    }
}
