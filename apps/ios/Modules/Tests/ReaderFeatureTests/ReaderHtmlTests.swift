import Foundation
import SrokaCore
import SrokaDesign
import Testing

@testable import ReaderFeature

struct ReaderHtmlTests {
    private let base = "sroka-article://item-1/"

    private func wrap(
        _ html: String,
        theme: EffectiveTheme = .light,
        scale: Double = 1.0,
        font: ReaderFont = .sans,
        spacing: ReaderLineSpacing = .normal,
        header: ReaderHeader? = nil
    ) -> String {
        ReaderHtml.wrap(
            articleHtml: html, baseURL: base, theme: theme, textScale: scale, font: font, lineSpacing: spacing,
            header: header)
    }

    // MARK: Wrapper

    @Test func `A fragment becomes a complete document with the theme attributes`() {
        let result = wrap("<p>Hello</p>", theme: .sepia, scale: 1.2, font: .serif, spacing: .loose)
        #expect(result.hasPrefix("<!doctype html>"))
        #expect(result.contains("data-theme=\"sepia\""))
        #expect(result.contains("data-font=\"serif\""))
        #expect(result.contains("--scale:1.20"))
        #expect(result.contains("--lh:1.9"))
        #expect(result.contains("<p>Hello</p>"))
    }

    @Test func `The page may load only from the article scheme`() {
        let result = wrap("<p>x</p>")
        #expect(result.contains("Content-Security-Policy"))
        #expect(result.contains("default-src 'none'"))
        #expect(result.contains("img-src sroka-article: data:"))
        #expect(!result.contains("http-equiv=\"refresh\""))
        #expect(result.contains("<base href=\"sroka-article://item-1/\">"))
    }

    @Test func `A full document keeps its structure and gets the head content first`() {
        let article = "<html lang=\"en\"><head><title>T</title></head><body><p>Hi</p></body></html>"
        let result = wrap(article, theme: .dark)
        #expect(result.contains("<html data-theme=\"dark\""))
        let head = result.range(of: "<head>")
        let csp = result.range(of: "Content-Security-Policy")
        #expect(head != nil && csp != nil && head!.upperBound <= csp!.lowerBound)
        #expect(result.contains("<title>T</title>"))
        #expect(result.contains("<p>Hi</p>"))
    }

    @Test func `A document without a head gets one`() {
        let result = wrap("<html><body><p>Hi</p></body></html>")
        #expect(result.contains("<head><meta charset=\"utf-8\">"))
        #expect(result.contains("Content-Security-Policy"))
    }

    @Test func `The end padding is clamped`() {
        let big = ReaderHtml.wrap(
            articleHtml: "<p/>", baseURL: base, theme: .light, textScale: 1, endPaddingPx: 99_999)
        #expect(big.contains("--end:1000px"))
        let negative = ReaderHtml.wrap(
            articleHtml: "<p/>", baseURL: base, theme: .light, textScale: 1, endPaddingPx: -5)
        #expect(negative.contains("--end:0px"))
    }

    // MARK: Theme CSS

    @Test(arguments: [(EffectiveTheme.light, "light"), (.sepia, "sepia"), (.dark, "dark")])
    func `Each theme defines its colours as CSS variables`(theme: EffectiveTheme, name: String) {
        #expect(theme.cssName == name)
        let css = ReaderHtml.css
        if theme != .light {
            #expect(css.contains("html[data-theme=\(name)]{"))
        }
        let palette = theme.palette
        #expect(css.lowercased().contains(palette.backgroundHex.lowercased()))
        #expect(css.lowercased().contains(palette.textHex.lowercased()))
        #expect(css.lowercased().contains(palette.linkHex.lowercased()))
    }

    @Test func `The font stacks are the system faces`() {
        let css = ReaderHtml.css
        #expect(css.contains("system-ui"))
        #expect(css.contains("ui-serif"))
        #expect(css.contains("var(--scale)") || css.contains("--scale"))
    }

    @Test func `Line spacing and text size follow the stored choices`() {
        #expect(ReaderLineSpacing.tight.lineHeight == 1.45)
        #expect(ReaderLineSpacing.normal.lineHeight == 1.65)
        #expect(ReaderLineSpacing.loose.lineHeight == 1.9)
        #expect(ReaderTextScale.px(1.0) == 18)
        #expect(ReaderTextScale.px(0.8) == 14)
        #expect(ReaderTextScale.px(1.6) == 29)
    }

    @Test func `Auto follows the system appearance`() {
        #expect(EffectiveTheme.resolve(.auto, systemDark: true) == .dark)
        #expect(EffectiveTheme.resolve(.auto, systemDark: false) == .light)
        #expect(EffectiveTheme.resolve(.sepia, systemDark: true) == .sepia)
        #expect(EffectiveTheme.resolve(.light, systemDark: true) == .light)
    }

    // MARK: Live updates

    @Test func `The appearance script restyles the open page without a reload`() {
        let script = ReaderHtml.appearanceScript(theme: .dark, textScale: 1.4, font: .serif, lineSpacing: .loose)
        #expect(script.contains("__srokaSetAppearance"))
        #expect(script.contains("'dark',1.40,'serif',"))
    }

    // MARK: Header

    @Test func `The header is escaped, never interpreted`() {
        let header = ReaderHeader(
            site: "A & B", title: "<script>alert(1)</script>", metaPrefix: "4 min read · ", progress: 0.256,
            partialWarning: "Partial copy")
        let result = wrap("<p>x</p>", header: header)
        #expect(!result.contains("<script>alert(1)</script>"))
        #expect(result.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(result.contains("A &amp; B"))
        #expect(result.contains("sk-warn"))
        #expect(result.contains("4 min read · "))
        #expect(result.contains(">26%<"))
    }

    @Test func `Without a header or warning those parts are absent`() {
        #expect(!wrap("<p>x</p>").contains("<header class=\"sk-head\""))
        let header = ReaderHeader(site: "S", title: "T", metaPrefix: "", progress: 0, partialWarning: nil)
        let result = wrap("<p>x</p>", header: header)
        #expect(result.contains("<header class=\"sk-head\""))
        #expect(!result.contains("class=\"sk-warn\""))
    }

    @Test func `A header is placed before the article body of a full document`() {
        let header = ReaderHeader(site: "S", title: "T", metaPrefix: "", progress: 0, partialWarning: nil)
        let result = wrap("<html><head></head><body><p>Hi</p></body></html>", header: header)
        let head = result.range(of: "<header class=\"sk-head\"")
        let body = result.range(of: "<p>Hi</p>")
        #expect(head != nil && body != nil && head!.lowerBound < body!.lowerBound)
    }

    @Test func `Header values travel as data, not code`() {
        let header = ReaderHeader(
            site: "</script><b>", title: "\"quoted\" \\ back\nslash", metaPrefix: "", progress: 0, partialWarning: nil)
        let script = ReaderHtml.headerScript(header)
        #expect(!script.contains("</script>"))
        #expect(!script.contains("<b>"))
        #expect(script.hasPrefix("window.__srokaSetHeader&&window.__srokaSetHeader("))
    }

    @Test func `JSON strings are safe inside script and HTML`() {
        let text = ReaderHtml.jsonString("</script>&\u{2028}\"\\\n")
        #expect(!text.contains("<"))
        #expect(!text.contains(">"))
        #expect(!text.contains("&"))
        #expect(!text.contains("\u{2028}"))
        #expect(text.hasPrefix("\"") && text.hasSuffix("\""))
    }

    // MARK: Reader script

    @Test func `The script carries the start position and the handler name`() {
        let script = ReaderHtml.script(startAnchor: 31, startProgress: 0.42)
        #expect(script.contains("31"))
        #expect(script.contains("0.4200"))
        #expect(script.contains(ReaderHtml.messageHandlerName))
        #expect(script.contains(Limits.progressAnchorSelector))
        #expect(!script.contains("__SEL__") && !script.contains("__START_") && !script.contains("__HANDLER__"))
    }

    @Test func `With no saved anchor the script starts from the progress`() {
        let script = ReaderHtml.script(startAnchor: nil, startProgress: 5)
        #expect(script.contains("null"))
        #expect(script.contains("1.0000"))
    }

    @Test func `In-page links scroll by id`() {
        #expect(ReaderHtml.scrollToIdScript("section-2").contains("\"section-2\""))
    }

    // MARK: Progress messages

    @Test func `Progress messages parse`() {
        #expect(parseProgressMessage("0.5321|12|1") == ProgressReport(progress: 0.5321, anchor: 12, atEnd: true))
        #expect(parseProgressMessage("0.5|7|0") == ProgressReport(progress: 0.5, anchor: 7, atEnd: false))
        #expect(parseProgressMessage("0.2|") == ProgressReport(progress: 0.2, anchor: nil, atEnd: false))
        #expect(parseProgressMessage("1.7|3") == ProgressReport(progress: 1, anchor: 3, atEnd: false))
        #expect(parseProgressMessage("-0.3|3") == ProgressReport(progress: 0, anchor: 3, atEnd: false))
        #expect(parseProgressMessage("0.5|-4") == ProgressReport(progress: 0.5, anchor: nil, atEnd: false))
    }

    @Test(arguments: ["", "abc|1", "0.5", "0.5|x", "0.5|1|2", "nan|1", "inf|1", "0.5|1|1|1", "|"])
    func `Malformed progress messages are ignored`(message: String) {
        #expect(parseProgressMessage(message) == nil)
    }

    @Test func `Messages that are not strings are ignored`() {
        #expect(parseProgressMessage(nil) == nil)
        #expect(parseProgressMessage(42) == nil)
        #expect(parseProgressMessage(["0.5|1"]) == nil)
    }
}
