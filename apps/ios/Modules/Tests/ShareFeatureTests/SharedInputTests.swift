import Foundation
import Testing
import UniformTypeIdentifiers

@testable import ShareFeature

@MainActor
struct SharedInputTests {
    let directory: URL
    let extractor: ShareInputExtractor

    init(maxPdfBytes: Int64 = 1024) throws {
        directory = URL.temporaryDirectory.appending(
            path: "share-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        extractor = ShareInputExtractor(maxPdfBytes: maxPdfBytes, stagingDirectory: directory.appending(path: "staged"))
    }

    // MARK: Builders

    func item(_ providers: [NSItemProvider], title: String? = nil, contentText: String? = nil) -> NSExtensionItem {
        let item = NSExtensionItem()
        item.attachments = providers
        if let title { item.attributedTitle = NSAttributedString(string: title) }
        if let contentText { item.attributedContentText = NSAttributedString(string: contentText) }
        return item
    }

    func urlProvider(_ string: String) -> NSItemProvider {
        NSItemProvider(object: URL(string: string)! as NSURL)
    }

    func textProvider(_ text: String) -> NSItemProvider {
        NSItemProvider(item: text as NSString, typeIdentifier: UTType.plainText.identifier)
    }

    func pdfProvider(name: String = "doc.pdf", contents: String) throws -> NSItemProvider {
        let url = directory.appending(path: name)
        try Data(contents.utf8).write(to: url)
        return try #require(NSItemProvider(contentsOf: url))
    }

    // MARK: Links

    @Test func `A URL attachment is the link`() async {
        let input = await extractor.extract(from: [item([urlProvider("https://example.com/a?x=1")])])
        #expect(input == .link(url: "https://example.com/a?x=1", title: nil))
    }

    @Test func `The page title comes along unless it is only a link`() async {
        let titled = await extractor.extract(from: [
            item([urlProvider("https://example.com/a")], title: "  A good read ")
        ])
        #expect(titled == .link(url: "https://example.com/a", title: "A good read"))
        let linkTitle = await extractor.extract(from: [
            item([urlProvider("https://example.com/a")], title: "https://example.com/a")
        ])
        #expect(linkTitle == .link(url: "https://example.com/a", title: nil))
    }

    @Test(arguments: [
        ("Read this: https://example.com/a-b.", "https://example.com/a-b"),
        ("(see https://example.com/x)", "https://example.com/x"),
        ("https://en.wikipedia.org/wiki/Foo_(bar), nice", "https://en.wikipedia.org/wiki/Foo_(bar)"),
        ("a\nhttps://example.com/one https://example.com/two", "https://example.com/one"),
        ("“https://example.com/q?a=1&b=2”!", "https://example.com/q?a=1&b=2"),
    ])
    func `The first link in shared text is found`(text: String, expected: String) async {
        let input = await extractor.extract(from: [item([textProvider(text)])])
        #expect(input == .link(url: expected, title: nil))
    }

    @Test func `A URL attachment wins over text`() async {
        let input = await extractor.extract(from: [
            item([textProvider("also https://example.com/text"), urlProvider("https://example.com/attachment")])
        ])
        #expect(input == .link(url: "https://example.com/attachment", title: nil))
    }

    @Test func `The item's own text is used when it has no attachments with a link`() async {
        let input = await extractor.extract(from: [item([], contentText: "look: https://example.com/body")])
        #expect(input == .link(url: "https://example.com/body", title: nil))
    }

    @Test(arguments: ["no link in here", "mailto:someone@example.com", "ftp://example.com/file", ""])
    func `Text without a web link finds nothing`(text: String) async {
        let input = await extractor.extract(from: [item([textProvider(text)])])
        #expect(input == .nothing)
    }

    @Test func `A non web URL attachment finds nothing`() async {
        let input = await extractor.extract(from: [item([urlProvider("mailto:someone@example.com")])])
        #expect(input == .nothing)
    }

    @Test func `No attachments find nothing`() async {
        #expect(await extractor.extract(from: []) == .nothing)
        #expect(await extractor.extract(from: [item([])]) == .nothing)
    }

    // MARK: PDF

    @Test func `A PDF file is staged for the uploader`() async throws {
        let provider = try pdfProvider(contents: "%PDF-1.7\nbody")
        guard case .pdfs(let urls) = await extractor.extract(from: [item([provider])]) else {
            Issue.record("expected pdfs")
            return
        }
        let url = try #require(urls.first)
        #expect(urls.count == 1)
        #expect(try Data(contentsOf: url) == Data("%PDF-1.7\nbody".utf8))
        #expect(url.path.hasPrefix(directory.appending(path: "staged").path))
        ShareInputExtractor.discard(urls)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    @Test func `A file URL attachment next to a PDF does not count as a link`() async throws {
        let provider = try pdfProvider(contents: "%PDF-1.4")
        let fileURL = NSItemProvider(object: directory.appending(path: "doc.pdf") as NSURL)
        guard case .pdfs = await extractor.extract(from: [item([fileURL, provider])]) else {
            Issue.record("expected pdfs")
            return
        }
    }

    @Test func `A link wins over a PDF in the same share`() async throws {
        let provider = try pdfProvider(contents: "%PDF-1.4")
        let input = await extractor.extract(from: [item([provider, urlProvider("https://example.com/page")])])
        #expect(input == .link(url: "https://example.com/page", title: nil))
    }

    @Test func `A file without the PDF header is rejected`() async throws {
        let provider = try pdfProvider(contents: "<html>not a pdf</html>")
        #expect(await extractor.extract(from: [item([provider])]) == .rejectedPdf(.notPdf))
    }

    @Test func `A PDF over the size cap is rejected`() async throws {
        let provider = try pdfProvider(contents: "%PDF-" + String(repeating: "x", count: 2000))
        #expect(await extractor.extract(from: [item([provider])]) == .rejectedPdf(.tooLarge))
    }

    @Test func `One good PDF among rejected ones is still staged`() async throws {
        let bad = try pdfProvider(name: "bad.pdf", contents: "nope")
        let good = try pdfProvider(name: "good.pdf", contents: "%PDF-1.7")
        guard case .pdfs(let urls) = await extractor.extract(from: [item([bad, good])]) else {
            Issue.record("expected pdfs")
            return
        }
        #expect(urls.count == 1)
        #expect(try Data(contentsOf: #require(urls.first)) == Data("%PDF-1.7".utf8))
    }
}
