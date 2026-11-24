import Dependencies
import Foundation

/// Reader-facing part of offline article storage (DECISIONS A9/A10). Packages live in the App Group
/// container at `articles/{itemId}/` (`article.html`, `img/…`, or `document.pdf` for PDF items) and are
/// served to `WKWebView` by the reader's own `sroka-article://` scheme handler. Android: ContentStore.kt.
public protocol ContentStore: Sendable {
    /// Offline state of one item's article package.
    func observeOffline(itemId: String) -> AsyncStream<OfflineState>

    /// The downloaded `article.html`, or nil if not downloaded.
    func articleHtml(itemId: String) async -> String?

    /// Root directory of unpacked packages (`articles/`), for the scheme handler.
    func articlesDirectory() -> URL

    /// Downloads this item's package now (reader "not downloaded yet" path).
    func downloadNow(itemId: String) async -> DownloadResult

    /// The downloaded original of a PDF item, or nil if it is not on disk. Never touches the network.
    func pdfFile(itemId: String) async -> URL?

    /// Bytes used by article packages and thumbnails.
    func storageUsageBytes() async -> Int64

    /// Deletes every downloaded package; items become `.availableRemote`.
    func clearDownloads() async
}

extension ContentStore {
    /// Local file for a PDF item, downloading it first when needed.
    public func ensurePdfFile(itemId: String) async -> PdfFileResult {
        if let file = await pdfFile(itemId: itemId) { return .ready(file) }
        switch await downloadNow(itemId: itemId) {
        case .downloaded:
            if let file = await pdfFile(itemId: itemId) { return .ready(file) }
            return .failed(.server)
        case .notReady:
            return .notReady
        case .failed(let reason, let code):
            return .failed(reason, code: code)
        case .storageFull(let code):
            return .storageFull(code: code)
        }
    }
}

public enum DownloadResult: Sendable, Hashable {
    case downloaded
    /// The server has not finished parsing the article yet (HTTP 409 `not_parsed`).
    case notReady
    /// `code` is a short ASCII diagnostic (`http_403`, `bad_zip`) for the reader's error screen; never personal data.
    case failed(RemoteFailure, code: String? = nil)
    /// The device is out of free space or a local write failed; not the server's fault. `code` is
    /// `free_space <bytes>` or `io <domain> <code>`.
    case storageFull(code: String)
}

public enum PdfFileResult: Sendable, Hashable {
    case ready(URL)
    /// The server has no document for this item (yet).
    case notReady
    case failed(RemoteFailure, code: String? = nil)
    case storageFull(code: String)
}

private struct UnimplementedContentStore: ContentStore {
    private func fail(_ method: String) { reportUnimplemented("ContentStore.\(method)", key: "contentStore") }

    func observeOffline(itemId: String) -> AsyncStream<OfflineState> {
        fail("observeOffline")
        return .finished
    }
    func articleHtml(itemId: String) async -> String? {
        fail("articleHtml")
        return nil
    }
    func articlesDirectory() -> URL {
        fail("articlesDirectory")
        return URL(filePath: NSTemporaryDirectory()).appending(path: "articles", directoryHint: .isDirectory)
    }
    func downloadNow(itemId: String) async -> DownloadResult {
        fail("downloadNow")
        return .failed(.server)
    }
    func pdfFile(itemId: String) async -> URL? {
        fail("pdfFile")
        return nil
    }
    func storageUsageBytes() async -> Int64 {
        fail("storageUsageBytes")
        return 0
    }
    func clearDownloads() async { fail("clearDownloads") }
}

private enum ContentStoreKey: TestDependencyKey {
    static let testValue: any ContentStore = UnimplementedContentStore()
}

extension DependencyValues {
    public var contentStore: any ContentStore {
        get { self[ContentStoreKey.self] }
        set { self[ContentStoreKey.self] = newValue }
    }
}
