import CoreGraphics
import CoreText
import Foundation

/// A real, unpacked article package on disk for previews, tests and snapshots (the shape the live
/// content store produces: `articles/{itemId}/article.html` plus `img/…`, and `document.pdf` for PDFs).
/// `FakeContentStore` writes it into its own temporary directory on first use.
public enum SamplePackage {
    /// Writes `article.html` and its images under `directory/{itemId}/`. Safe to call repeatedly.
    @discardableResult
    public static func install(itemId: String, title: String, in directory: URL) throws -> String {
        let itemDirectory = directory.appending(path: itemId, directoryHint: .isDirectory)
        let imageDirectory = itemDirectory.appending(path: "img", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let html = articleHtml(title: title)
        try Data(html.utf8).write(to: itemDirectory.appending(path: "article.html"), options: .atomic)
        try Data(heroSvg.utf8).write(to: imageDirectory.appending(path: "hero.svg"), options: .atomic)
        try Data(avatarSvg.utf8).write(to: imageDirectory.appending(path: "avatar.svg"), options: .atomic)
        return html
    }

    /// Writes a small multi-page PDF to `directory/{itemId}/document.pdf` and returns its URL.
    public static func installPdf(itemId: String, pageCount: Int = 12, in directory: URL) throws -> URL {
        let itemDirectory = directory.appending(path: itemId, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
        let file = itemDirectory.appending(path: "document.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(file as CFURL, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for page in 1...max(pageCount, 1) {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0.98, alpha: 1))
            context.fill(box)
            let text = NSAttributedString(
                string: "Sample document\nPage \(page)",
                attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName(
                        "Helvetica" as CFString, 28, nil)
                ]
            )
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            let path = CGPath(rect: box.insetBy(dx: 72, dy: 96), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), context)
            context.endPDFPage()
        }
        context.closePDF()
        return file
    }

    /// The sanitized-article markup (no `<html>` wrapper): headings, an image figure, a post card, a quote,
    /// a code block and enough paragraphs to scroll for several screens.
    public static func articleHtml(title: String) -> String {
        let escaped = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let paragraphs = (1...6).map { index in
            "<p>\(paragraphText(index))</p>"
        }
        let more = (7...16).map { index in
            "<p>\(paragraphText(index))</p>"
        }
        return """
            <article>
            <h1>\(escaped)</h1>
            <p class="byline">By A. Writer</p>
            <p><strong>Reading offline is a feature, not a fallback.</strong> The best long articles reward attention, and attention needs a calm page.</p>
            <figure><img src="img/hero.svg" alt="A coloured landscape" width="800" height="400"><figcaption>An image served from the article package.</figcaption></figure>
            \(paragraphs.joined(separator: "\n"))
            <h2>A post worth quoting</h2>
            <div class="sr-thread"><div class="sr-post sr-post-focus"><div class="sr-post-head"><img class="sr-avatar" src="img/avatar.svg" alt=""><span class="sr-post-who"><strong>Ada Reader</strong> @ada · 2h</span></div><div class="sr-post-body"><p>Pocket is gone, long live the magpie. Saved for later, read when it suits.</p></div><div class="sr-post-stats">128 likes · 14 reposts</div></div></div>
            <blockquote><p>Simplicity is prerequisite for reliability.</p></blockquote>
            <h2>Some code</h2>
            <pre><code>let magpie = Library.save(url)\nmagpie.read(offline: true)</code></pre>
            <ul><li>Local-first</li><li>No account wall</li><li>One tap to archive</li></ul>
            <h3>The rest of the story</h3>
            \(more.joined(separator: "\n"))
            <p>That is all, and it is enough.</p>
            </article>
            """
    }

    private static func paragraphText(_ index: Int) -> String {
        let sentences = [
            "A read-later app lives or dies by the quiet moment when you finally open the thing you saved.",
            "The text should already be there, on the device, laid out so that your eyes can simply keep going.",
            "Sentence \(index) carries on the thought: images load from the package, links never leave the page unannounced,",
            "and the place where you stopped is remembered down to the paragraph, whichever device you pick up next.",
        ]
        return sentences.joined(separator: " ")
    }

    static let heroSvg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 400" width="800" height="400">\
        <rect width="800" height="400" fill="#cfe6ee"/><circle cx="640" cy="110" r="52" fill="#f2c94c"/>\
        <path d="M0 400V270l150-90 140 80 170-130 200 110 140-60v220z" fill="#1e6f8f"/>\
        <path d="M0 400V320l180-60 190 50 200-70 230 80v80z" fill="#15171c"/></svg>
        """

    static let avatarSvg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40" width="40" height="40">\
        <circle cx="20" cy="20" r="20" fill="#1e6f8f"/><circle cx="20" cy="15" r="7" fill="#fbfbf9"/>\
        <path d="M6 36c2-9 9-12 14-12s12 3 14 12z" fill="#fbfbf9"/></svg>
        """
}
