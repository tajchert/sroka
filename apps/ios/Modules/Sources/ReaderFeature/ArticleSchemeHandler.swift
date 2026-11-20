import Foundation
import OSLog
import SrokaCore
import WebKit

/// The custom scheme the reader serves article packages from: `sroka-article://{itemId}/img/…`.
enum ArticleScheme {
    static let name = "sroka-article"

    static func baseURL(itemId: String) -> URL? {
        guard isValidItemId(itemId) else { return nil }
        return URL(string: "\(name)://\(itemId)/")
    }
}

/// What a request for an article resource resolves to.
enum ArticleResolution: Equatable, Sendable {
    case file(URL, mimeType: String)
    case notFound
}

/// Maps `sroka-article://{itemId}/{path}` to a file inside that item's unpacked package, and nothing else.
///
/// Pure and synchronous so it is unit-testable: the item id must be valid (`^[A-Za-z0-9_-]{1,64}$`), the path
/// may not contain `.` / `..` / empty / backslash / NUL components, the file must be a regular file whose
/// symlink-resolved location is still inside the item directory, and only image types are served (the page's CSP
/// allows nothing else). Anything else is `notFound`.
struct ArticleResourceResolver: Sendable {
    /// `ContentStore.articlesDirectory()`: one sub-directory per item id.
    let articlesDirectory: URL
    /// The one item this resolver serves; URLs naming another item resolve to nothing.
    let itemId: String
    /// Larger files are refused (a package image is a few MB at most).
    static let maxFileBytes = 25 * 1024 * 1024

    static let mimeTypes: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "avif": "image/avif",
        "svg": "image/svg+xml",
    ]

    func resolve(_ url: URL) -> ArticleResolution {
        guard url.scheme?.lowercased() == ArticleScheme.name,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.user == nil, components.password == nil, components.port == nil,
            let host = components.host, isValidItemId(host), isValidItemId(itemId),
            host.caseInsensitiveCompare(itemId) == .orderedSame,
            let itemDirectory = itemDirectory()
        else { return .notFound }

        let path = components.path
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\") else { return .notFound }
        let relative = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty,
            relative.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return .notFound }

        let file = relative.reduce(itemDirectory) { $0.appendingPathComponent(String($1)) }
        guard let mimeType = Self.mimeTypes[file.pathExtension.lowercased()] else { return .notFound }

        // Resolve symlinks before checking containment: a link inside the package must not lead out of it.
        let root = itemDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(root + "/") else { return .notFound }
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true, let size = values.fileSize, size <= Self.maxFileBytes
        else { return .notFound }
        return .file(resolved, mimeType: mimeType)
    }

    /// The package directory of this resolver's item, built from `itemId` (never from the request host, which WebKit
    /// may lower-case; the host is only validated against `itemId`).
    private func itemDirectory() -> URL? {
        let directory = articlesDirectory.appendingPathComponent(itemId, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        return directory
    }
}

/// Serves the files of the open article's package to the web view. Only GET of image files under the one item
/// this handler was created for is answered; every other request gets a 404 (the content rule list blocks
/// http/https, so this is the page's only source of resources).
@MainActor
final class ArticleSchemeHandler: NSObject, WKURLSchemeHandler {
    private let itemId: String
    private let resolver: ArticleResourceResolver
    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: "app.sroka", category: "reader.scheme")

    init(itemId: String, articlesDirectory: URL) {
        self.itemId = itemId
        self.resolver = ArticleResourceResolver(articlesDirectory: articlesDirectory, itemId: itemId)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject)
        let request = urlSchemeTask.request
        let resolver = resolver
        let task = Task { [weak self] in
            let loaded: (Data, String)? = await Task.detached(priority: .userInitiated) {
                guard request.httpMethod == nil || request.httpMethod == "GET", let url = request.url,
                    case .file(let file, let mimeType) = resolver.resolve(url),
                    let data = try? Data(contentsOf: file, options: .mappedIfSafe)
                else { return nil }
                return (data, mimeType)
            }.value
            // `stop` removes the entry; completing a stopped task raises an exception.
            guard let self, !Task.isCancelled, self.running[key] != nil else { return }
            self.running[key] = nil
            self.finish(urlSchemeTask, with: loaded)
        }
        running[key] = task
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject)
        running[key]?.cancel()
        running[key] = nil
    }

    private func finish(_ task: any WKURLSchemeTask, with loaded: (Data, String)?) {
        guard let url = task.request.url else { return }
        let headers: [String: String]
        let status: Int
        let body: Data
        if let (data, mimeType) = loaded {
            status = 200
            body = data
            headers = [
                "Content-Type": mimeType, "Content-Length": String(data.count), "Cache-Control": "no-store",
                "X-Content-Type-Options": "nosniff",
            ]
        } else {
            status = 404
            body = Data()
            headers = ["Content-Length": "0"]
            logger.debug("article resource not served")
        }
        guard
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }
}
