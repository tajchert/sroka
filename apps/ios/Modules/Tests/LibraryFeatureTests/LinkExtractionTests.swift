import Testing

@testable import LibraryFeature

struct LinkExtractionTests {
    @Test func `Finds the first link in shared text`() {
        #expect(LinkExtraction.firstURL(in: "Read this https://example.com/a?b=1 now") == "https://example.com/a?b=1")
    }

    @Test func `Strips trailing punctuation and unbalanced brackets`() {
        #expect(LinkExtraction.firstURL(in: "see (https://example.com/page).") == "https://example.com/page")
        #expect(LinkExtraction.firstURL(in: "https://example.com/a_(b)") == "https://example.com/a_(b)")
        #expect(LinkExtraction.firstURL(in: "“https://example.com/x”,") == "https://example.com/x")
    }

    @Test func `Text without a web address has no link`() {
        #expect(LinkExtraction.firstURL(in: "just words") == nil)
        #expect(LinkExtraction.link(from: "ftp://example.com/file") == nil)
        #expect(LinkExtraction.link(from: "example.com") == nil)
    }

    @Test func `A typed address is trimmed`() {
        #expect(LinkExtraction.link(from: "  https://example.com/x \n") == "https://example.com/x")
    }
}
