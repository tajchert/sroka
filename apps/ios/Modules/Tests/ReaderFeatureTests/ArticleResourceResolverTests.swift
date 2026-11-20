import Foundation
import Testing

@testable import ReaderFeature

/// The scheme handler serves only what this resolver allows: files inside the one item's package directory.
struct ArticleResourceResolverTests {
    /// `root/item-1/{article.html, notes.txt, img/{a.png, b.svg, big.png, link.png, linkdir/…}}` and
    /// `root/item-2/img/secret.png`, with links from item-1 to item-2.
    private final class Package {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "sroka-resolver-\(UUID().uuidString)", directoryHint: .isDirectory)

        init() throws {
            let manager = FileManager.default
            let img1 = root.appending(path: "item-1/img", directoryHint: .isDirectory)
            let img2 = root.appending(path: "item-2/img", directoryHint: .isDirectory)
            try manager.createDirectory(at: img1, withIntermediateDirectories: true)
            try manager.createDirectory(at: img2, withIntermediateDirectories: true)
            try Data("<html></html>".utf8).write(to: root.appending(path: "item-1/article.html"))
            try Data("secret notes".utf8).write(to: root.appending(path: "item-1/notes.txt"))
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: img1.appending(path: "a.png"))
            try Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8).write(to: img1.appending(path: "b.svg"))
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: img2.appending(path: "secret.png"))
            // A sparse 26 MB file: over the size limit without writing 26 MB.
            manager.createFile(atPath: img1.appending(path: "big.png").path, contents: nil)
            let handle = try FileHandle(forWritingTo: img1.appending(path: "big.png"))
            try handle.truncate(atOffset: UInt64(ArticleResourceResolver.maxFileBytes + 1))
            try handle.close()
            try manager.createSymbolicLink(
                at: img1.appending(path: "link.png"), withDestinationURL: img2.appending(path: "secret.png"))
            try manager.createSymbolicLink(
                at: img1.appending(path: "linkdir"), withDestinationURL: img2)
            try manager.createSymbolicLink(
                at: root.appending(path: "item-1/inner.png"), withDestinationURL: img1.appending(path: "a.png"))
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func resolver(itemId: String = "item-1") -> ArticleResourceResolver {
            ArticleResourceResolver(articlesDirectory: root, itemId: itemId)
        }
    }

    private func resolve(_ string: String, itemId: String = "item-1", in package: Package) -> ArticleResolution {
        guard let url = URL(string: string) else { return .notFound }
        return package.resolver(itemId: itemId).resolve(url)
    }

    @Test func `An image inside the item's package is served with its type`() throws {
        let package = try Package()
        guard case .file(let url, let mime) = resolve("sroka-article://item-1/img/a.png", in: package) else {
            Issue.record("not served")
            return
        }
        #expect(url.lastPathComponent == "a.png")
        #expect(mime == "image/png")
        guard case .file(_, let svg) = resolve("sroka-article://item-1/img/b.svg", in: package) else {
            Issue.record("svg not served")
            return
        }
        #expect(svg == "image/svg+xml")
    }

    @Test func `The page's own base URL itself is not a file`() throws {
        let package = try Package()
        #expect(resolve("sroka-article://item-1/", in: package) == .notFound)
        #expect(resolve("sroka-article://item-1", in: package) == .notFound)
    }

    @Test func `Files that are not images are not served`() throws {
        let package = try Package()
        #expect(resolve("sroka-article://item-1/article.html", in: package) == .notFound)
        #expect(resolve("sroka-article://item-1/notes.txt", in: package) == .notFound)
    }

    @Test(arguments: [
        "sroka-article://item-1/../item-2/img/secret.png",
        "sroka-article://item-1/img/../../item-2/img/secret.png",
        "sroka-article://item-1/%2e%2e/item-2/img/secret.png",
        "sroka-article://item-1/img/%2E%2E/%2E%2E/item-2/img/secret.png",
        "sroka-article://item-1/img%2F..%2F..%2Fitem-2%2Fimg%2Fsecret.png",
        "sroka-article://item-1/img/./a.png",
        "sroka-article://item-1//img/a.png",
        "sroka-article://item-1/img//a.png",
        "sroka-article://item-1/img\\a.png",
        "sroka-article://item-1/img/a.png%00.txt",
        "sroka-article://item-1/img/a.png%00",
    ])
    func `Path traversal and odd paths are rejected`(string: String) throws {
        let package = try Package()
        #expect(resolve(string, in: package) == .notFound)
    }

    @Test func `Another item's package is out of reach`() throws {
        let package = try Package()
        #expect(resolve("sroka-article://item-2/img/secret.png", in: package) == .notFound)
        #expect(resolve("sroka-article://item-2/img/secret.png", itemId: "item-2", in: package) != .notFound)
    }

    @Test func `Links that lead out of the package are not followed`() throws {
        let package = try Package()
        #expect(resolve("sroka-article://item-1/img/link.png", in: package) == .notFound)
        #expect(resolve("sroka-article://item-1/img/linkdir/secret.png", in: package) == .notFound)
    }

    @Test func `A link that stays inside the package is fine`() throws {
        let package = try Package()
        guard case .file(let url, _) = resolve("sroka-article://item-1/inner.png", in: package) else {
            Issue.record("not served")
            return
        }
        #expect(url.lastPathComponent == "a.png")
    }

    @Test func `Missing files, folders and oversized files are not served`() throws {
        let package = try Package()
        #expect(resolve("sroka-article://item-1/img/none.png", in: package) == .notFound)
        #expect(resolve("sroka-article://item-1/img", in: package) == .notFound)
        #expect(resolve("sroka-article://item-1/img/big.png", in: package) == .notFound)
    }

    @Test(arguments: [
        "https://item-1/img/a.png",
        "http://item-1/img/a.png",
        "file:///etc/passwd",
        "sroka-content://item-1/img/a.png",
        "sroka-article://user@item-1/img/a.png",
        "sroka-article://user:pw@item-1/img/a.png",
        "sroka-article://item-1:8080/img/a.png",
        "sroka-article://item-1.evil.example/img/a.png",
        "sroka-article:///img/a.png",
    ])
    func `Only the article scheme with the plain item host is accepted`(string: String) throws {
        let package = try Package()
        #expect(resolve(string, in: package) == .notFound)
    }

    @Test(arguments: ["", "../x", "a/b", "a b", "a.b", String(repeating: "a", count: 65)])
    func `An invalid item id serves nothing`(id: String) throws {
        let package = try Package()
        #expect(package.resolver(itemId: id).resolve(URL(string: "sroka-article://item-1/img/a.png")!) == .notFound)
    }

    @Test func `A lower-cased host still finds a mixed-case item id`() throws {
        let package = try Package()
        let manager = FileManager.default
        let img = package.root.appending(path: "Item-Mixed/img", directoryHint: .isDirectory)
        try manager.createDirectory(at: img, withIntermediateDirectories: true)
        try Data([1]).write(to: img.appending(path: "a.png"))
        let url = try #require(URL(string: "sroka-article://item-mixed/img/a.png"))
        let resolution = package.resolver(itemId: "Item-Mixed").resolve(url)
        #expect(resolution != .notFound)
    }

    @Test func `The base URL is only built for valid ids`() {
        #expect(ArticleScheme.baseURL(itemId: "abc_123-X")?.absoluteString == "sroka-article://abc_123-X/")
        #expect(ArticleScheme.baseURL(itemId: "../x") == nil)
        #expect(ArticleScheme.baseURL(itemId: "") == nil)
    }
}
