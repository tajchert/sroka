import Testing

@testable import SrokaContent

struct HtmlTextTests {
    @Test func `Tags are stripped and whitespace collapsed`() {
        #expect(HtmlText.extract("<h1>Title</h1>\n<p>One   <b>two</b></p><p>three</p>") == "Title One two three")
    }

    @Test func `Scripts, styles, head and comments are dropped`() {
        let html = """
            <html><head><title>T</title><style>p{}</style></head><body>
            <!-- secret --><script type="x">var a = "<p>";</script><noscript>no</noscript>
            <template><p>t</p></template><p>Body</p><SCRIPT>x</SCRIPT></body></html>
            """
        #expect(HtmlText.extract(html) == "Body")
    }

    @Test func `Entities are decoded`() {
        #expect(
            HtmlText.extract("<p>Tom &amp; Jerry &lt;3 &#233;t&#xE9; &mdash; &nbsp;x&unknown;</p>")
                == "Tom & Jerry <3 été — x&unknown;")
    }

    @Test func `Invalid code points stay as written`() {
        #expect(HtmlText.decodeEntities("&#0; &#xD800; &#x110000;") == "&#0; &#xD800; &#x110000;")
    }

    @Test func `Long text is capped without splitting a surrogate pair`() {
        let long = String(repeating: "a", count: HtmlText.maxChars - 1) + "😀" + "tail"
        let text = HtmlText.extract(long)
        #expect(text.utf16.count == HtmlText.maxChars - 1)
        #expect(HtmlText.extract(String(repeating: "b ", count: HtmlText.maxChars)).utf16.count == HtmlText.maxChars)
    }
}
