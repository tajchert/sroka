import Foundation
import Testing

@testable import SrokaContent

struct PackageInstallerTests {
    let dir: TempDir
    let articles: URL

    init() throws {
        dir = try TempDir()
        articles = dir.url.appending(path: "articles", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: articles, withIntermediateDirectories: true)
    }

    private func install(
        _ entries: [ZipEntry], installer: PackageInstaller = PackageInstaller(), id: String = "item1"
    ) throws -> PackageInstaller.Result {
        let zip = dir.file("p-\(UUID().uuidString).zip")
        try makeZip(at: zip, entries)
        return installer.install(zip: zip, articlesDirectory: articles, itemId: id)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: articles.appending(path: path).path)
    }

    private func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: articles.path)) ?? []).sorted()
    }

    @Test func `A valid package is installed with its files`() throws {
        defer { dir.cleanUp() }
        let result = try install(validPackage())
        guard case .installed(let bytes) = result else {
            Issue.record("expected installed, got \(result)")
            return
        }
        #expect(bytes > 0)
        #expect(exists("item1/article.html"))
        #expect(exists("item1/img/a.webp"))
        #expect(leftovers() == ["item1"])
    }

    @Test(arguments: [
        "/etc/passwd", "../evil.html", "img/../../evil.html", "./article.html", "img\\evil.html", "C:evil.html",
        "a\u{0}b.html", String(repeating: "a", count: 513), "img//a.webp",
    ])
    func `Unsafe entry names are rejected and nothing is written`(name: String) throws {
        defer { dir.cleanUp() }
        var entries = validPackage()
        entries.append(.file(name, Data("x".utf8)))
        #expect(try install(entries) == .invalid(reason: "unsafe_path"))
        #expect(leftovers().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.url.appending(path: "evil.html").path))
    }

    @Test func `A symlink entry is rejected`() throws {
        defer { dir.cleanUp() }
        var entries = validPackage()
        entries.append(.symlink("img/link", target: "/etc/passwd"))
        #expect(try install(entries) == .invalid(reason: "unsafe_path"))
        #expect(leftovers().isEmpty)
    }

    /// A device keeps every container under `/private/var`; `/private/tmp` has the same "/private" alias.
    @Test func `A package installs under a private-prefixed directory`() throws {
        defer { dir.cleanUp() }
        let root = URL(filePath: "/private/tmp/sroka-installer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = dir.file("p-\(UUID().uuidString).zip")
        try makeZip(at: zip, validPackage())
        let result = PackageInstaller().install(zip: zip, articlesDirectory: root, itemId: "item1")
        guard case .installed = result else {
            Issue.record("expected an installed package, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "item1/article.html").path))
    }

    @Test func `Case-insensitive duplicate names are rejected`() throws {
        defer { dir.cleanUp() }
        var entries = validPackage()
        entries.append(.file("IMG/A.webp", Data("x".utf8)))
        #expect(try install(entries) == .invalid(reason: "duplicate_entry"))
    }

    @Test func `A file that is also a directory is rejected`() throws {
        defer { dir.cleanUp() }
        var entries = validPackage()
        entries.append(.file("img", Data("x".utf8)))
        #expect(try install(entries) == .invalid(reason: "path_conflict"))
    }

    @Test func `More entries than the cap are rejected`() throws {
        defer { dir.cleanUp() }
        var entries = validPackage()
        for index in 0..<5 { entries.append(.file("img/\(index).webp", Data("x".utf8))) }
        let installer = PackageInstaller(maxTotalBytes: PackageInstaller.maxTotalBytes, maxEntries: 6)
        #expect(try install(entries, installer: installer) == .invalid(reason: "too_many_entries"))
        #expect(PackageInstaller.maxEntries == 200)
    }

    @Test func `Unpacked bytes over the cap are rejected while writing`() throws {
        defer { dir.cleanUp() }
        var entries = validPackage()
        entries.append(.file("img/big.webp", Data(repeating: 0, count: 10_000)))
        let installer = PackageInstaller(maxTotalBytes: 5_000, maxEntries: 200)
        #expect(try install(entries, installer: installer) == .invalid(reason: "too_large"))
        #expect(leftovers().isEmpty)
        #expect(PackageInstaller.maxTotalBytes == 50 * 1024 * 1024)
    }

    @Test func `A package without a manifest is rejected`() throws {
        defer { dir.cleanUp() }
        #expect(try install([.file("article.html", Data("<p>x</p>".utf8))]) == .invalid(reason: "no_manifest"))
    }

    @Test func `A manifest that does not list article html is rejected`() throws {
        defer { dir.cleanUp() }
        let image = Data("img".utf8)
        let entries: [ZipEntry] = [
            .file("manifest.json", manifest([("img/a.webp", image)])),
            .file("article.html", Data("<p>x</p>".utf8)),
            .file("img/a.webp", image),
        ]
        #expect(try install(entries) == .invalid(reason: "no_article"))
    }

    @Test func `A broken manifest is rejected`() throws {
        defer { dir.cleanUp() }
        let entries: [ZipEntry] = [
            .file("manifest.json", Data("{not json".utf8)), .file("article.html", Data("<p>x</p>".utf8)),
        ]
        #expect(try install(entries) == .invalid(reason: "bad_manifest"))
    }

    @Test func `A manifest repeating a path is rejected before hashing`() throws {
        defer { dir.cleanUp() }
        let article = Data("<p>x</p>".utf8)
        let entries: [ZipEntry] = [
            .file("manifest.json", manifest([("article.html", article), ("Article.html", article)])),
            .file("article.html", article),
        ]
        #expect(try install(entries) == .invalid(reason: "bad_manifest"))
    }

    @Test func `A file listed but missing is rejected`() throws {
        defer { dir.cleanUp() }
        let article = Data("<p>x</p>".utf8)
        let entries: [ZipEntry] = [
            .file("manifest.json", manifest([("article.html", article), ("img/gone.webp", Data("g".utf8))])),
            .file("article.html", article),
        ]
        #expect(try install(entries) == .invalid(reason: "missing_file"))
    }

    @Test func `A SHA-256 mismatch is rejected and keeps the installed package`() throws {
        defer { dir.cleanUp() }
        _ = try install(validPackage(html: "<p>first</p>"))
        let article = Data("<p>second</p>".utf8)
        let entries: [ZipEntry] = [
            .file("manifest.json", manifest([("article.html", Data("<p>other</p>".utf8))])),
            .file("article.html", article),
        ]
        #expect(try install(entries) == .invalid(reason: "sha256_mismatch"))
        let html = try String(contentsOf: articles.appending(path: "item1/article.html"), encoding: .utf8)
        #expect(html == "<p>first</p>")
        #expect(leftovers() == ["item1"])
    }

    @Test func `Garbage instead of a zip is rejected`() throws {
        defer { dir.cleanUp() }
        let zip = dir.file("garbage.zip")
        try Data("not a zip at all".utf8).write(to: zip)
        #expect(
            PackageInstaller().install(zip: zip, articlesDirectory: articles, itemId: "item1")
                == .invalid(reason: "bad_zip"))
    }

    @Test func `An empty archive is rejected`() throws {
        defer { dir.cleanUp() }
        #expect(try install([]) != .installed(bytes: 0))
        #expect(leftovers().isEmpty)
    }

    @Test func `An invalid item id never becomes a path`() throws {
        defer { dir.cleanUp() }
        #expect(try install(validPackage(), id: "../x") == .invalid(reason: "unsafe_id"))
        #expect(leftovers().isEmpty)
    }

    @Test func `A new version replaces the old one`() throws {
        defer { dir.cleanUp() }
        _ = try install(validPackage(html: "<p>first</p>"))
        let result = try install(validPackage(html: "<p>second</p>"))
        #expect(result != .ioError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteOutOfSpace.rawValue))
        let html = try String(contentsOf: articles.appending(path: "item1/article.html"), encoding: .utf8)
        #expect(html == "<p>second</p>")
        #expect(leftovers() == ["item1"])
    }

    @Test func `An interrupted swap leaves the old version intact`() throws {
        defer { dir.cleanUp() }
        _ = try install(validPackage(html: "<p>first</p>"))
        // The second move (tmp -> target) fails, as if the process died or the disk filled mid-swap.
        let installer = PackageInstaller(maxTotalBytes: PackageInstaller.maxTotalBytes, maxEntries: 200) { from, to in
            if from.lastPathComponent.hasSuffix(".tmp") { throw CocoaError(.fileWriteOutOfSpace) }
            try FileManager.default.moveItem(at: from, to: to)
        }
        #expect(
            try install(validPackage(html: "<p>second</p>"), installer: installer)
                == .ioError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteOutOfSpace.rawValue))
        let html = try String(contentsOf: articles.appending(path: "item1/article.html"), encoding: .utf8)
        #expect(html == "<p>first</p>")
        #expect(leftovers() == ["item1"])
    }
}

struct SafeRelativePathTests {
    @Test func `Normal names pass and trailing slashes are dropped`() {
        #expect(PackageInstaller.safeRelativePath("article.html") == "article.html")
        #expect(PackageInstaller.safeRelativePath("img/a b.webp") == "img/a b.webp")
        #expect(PackageInstaller.safeRelativePath("img/") == "img")
        #expect(PackageInstaller.safeRelativePath(String(repeating: "a", count: 512)) != nil)
    }

    @Test func `Escaping names are refused`() {
        for name in ["", "/", "/a", "..", "a/..", "a/./b", "a\\b", "a:b", "a\u{0}"] {
            #expect(PackageInstaller.safeRelativePath(name) == nil, "\(name.debugDescription)")
        }
    }
}
