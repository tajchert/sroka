import Foundation
import SrokaCore

/// On-disk layout of offline content (DECISIONS A4/A9; Android `ContentPaths.kt`), under one root in the App
/// Group container:
///
/// ```
/// {root}/articles/{itemId}/        unpacked package (article.html, img/…) or document.pdf for PDF items
/// {root}/articles/{itemId}.tmp     package being unpacked / PDF being validated
/// {root}/articles/{itemId}.old     previous package during the swap
/// {root}/thumbs/{itemId}.webp      lead-image thumbnail (`content_files.thumb_path` = "thumbs/{itemId}.webp")
/// {root}/downloads/                package zips and thumbnail temp files while downloading
/// {root}/pdf-uploads/{id}.pdf      PDFs waiting to be uploaded (+ {id}.json metadata)
/// ```
///
/// Every directory is excluded from backup. Item ids are validated with `isValidItemId` before they become
/// path components; a method given an invalid id returns nil or does nothing.
public struct ContentPaths: Sendable {
    public static let articleFile = "article.html"
    public static let pdfFile = "document.pdf"
    static let tmpSuffix = ".tmp"
    static let oldSuffix = ".old"

    /// Base of the relative `thumb_path` values; pass it as the database mapping's `thumbnailBase`.
    public let root: URL
    public let articles: URL
    public let thumbs: URL
    public let downloads: URL
    public let pdfUploads: URL

    public init(root: URL) {
        self.root = root
        articles = root.appending(path: "articles", directoryHint: .isDirectory)
        thumbs = root.appending(path: "thumbs", directoryHint: .isDirectory)
        downloads = root.appending(path: "downloads", directoryHint: .isDirectory)
        pdfUploads = root.appending(path: "pdf-uploads", directoryHint: .isDirectory)
    }

    /// `{App Group container}/Content`, or nil when the group is not provisioned.
    public static func appGroup(_ groupIdentifier: String) -> ContentPaths? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
            .map { ContentPaths(root: $0.appending(path: "Content", directoryHint: .isDirectory)) }
    }

    // MARK: Per item

    public func articleDir(_ itemId: String) -> URL? {
        guard isValidItemId(itemId) else { return nil }
        return articles.appending(path: itemId, directoryHint: .isDirectory)
    }

    public func articleHtml(_ itemId: String) -> URL? {
        articleDir(itemId)?.appending(path: Self.articleFile, directoryHint: .notDirectory)
    }

    public func pdfFile(_ itemId: String) -> URL? {
        articleDir(itemId)?.appending(path: Self.pdfFile, directoryHint: .notDirectory)
    }

    func tmpDir(_ itemId: String) -> URL? {
        guard isValidItemId(itemId) else { return nil }
        return articles.appending(path: itemId + Self.tmpSuffix, directoryHint: .notDirectory)
    }

    func oldDir(_ itemId: String) -> URL? {
        guard isValidItemId(itemId) else { return nil }
        return articles.appending(path: itemId + Self.oldSuffix, directoryHint: .isDirectory)
    }

    /// Relative path stored in `content_files.thumb_path`.
    static func thumbRelativePath(_ itemId: String) -> String { "thumbs/\(itemId).webp" }

    public func thumb(_ itemId: String) -> URL? {
        guard isValidItemId(itemId) else { return nil }
        return thumbs.appending(path: "\(itemId).webp", directoryHint: .notDirectory)
    }

    func packageZip(_ itemId: String) -> URL? {
        guard isValidItemId(itemId) else { return nil }
        return downloads.appending(path: "\(itemId).zip", directoryHint: .notDirectory)
    }

    func thumbTemp(_ itemId: String) -> URL? {
        guard isValidItemId(itemId) else { return nil }
        return downloads.appending(path: "\(itemId).thumb", directoryHint: .notDirectory)
    }

    func pdfUpload(_ uploadId: String) -> URL? {
        guard isValidItemId(uploadId) else { return nil }
        return pdfUploads.appending(path: "\(uploadId).pdf", directoryHint: .notDirectory)
    }

    func pdfUploadMetadata(_ uploadId: String) -> URL? {
        guard isValidItemId(uploadId) else { return nil }
        return pdfUploads.appending(path: "\(uploadId).json", directoryHint: .notDirectory)
    }

    /// `thumb_path` as stored → file URL (relative paths resolve against `root`).
    func resolve(storedPath: String) -> URL {
        storedPath.hasPrefix("/")
            ? URL(filePath: storedPath, directoryHint: .notDirectory)
            : root.appending(path: storedPath, directoryHint: .notDirectory)
    }

    // MARK: Whole layout

    /// Creates `dir` (and the root) if needed and marks it excluded from backup.
    func prepare(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// Creates all directories excluded from backup (best effort).
    public func prepareAll() {
        for dir in [articles, thumbs, downloads, pdfUploads] { try? prepare(dir) }
    }

    /// Removes the package, thumbnail and partial downloads of one item. No-op for an invalid id.
    public func deleteItemFiles(_ itemId: String) {
        guard isValidItemId(itemId) else { return }
        let candidates = [
            articleDir(itemId), tmpDir(itemId), oldDir(itemId), thumb(itemId), packageZip(itemId), thumbTemp(itemId),
        ]
        for url in candidates.compactMap({ $0 }) { removeIfPresent(url) }
    }

    /// "Remove downloaded articles": packages, thumbnails and partial downloads. Pending PDF uploads stay.
    func deleteDownloads() {
        for dir in [articles, thumbs, downloads] { removeIfPresent(dir) }
    }

    /// Sign-out wipe: everything, pending uploads included.
    func deleteEverything() {
        for dir in [articles, thumbs, downloads, pdfUploads] { removeIfPresent(dir) }
    }

    /// Bytes on disk used by packages and thumbnails.
    func usageBytes() -> Int64 { Self.size(of: articles) + Self.size(of: thumbs) }

    /// Free bytes for important data on the volume that holds the packages.
    func availableBytes() -> Int64 {
        var dir: URL? = articles
        while let current = dir {
            if FileManager.default.fileExists(atPath: current.path) {
                let values = try? current.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                return values?.volumeAvailableCapacityForImportantUsage ?? Int64.max
            }
            let parent = current.deletingLastPathComponent()
            dir = parent.path == current.path ? nil : parent
        }
        return Int64.max
    }

    func removeIfPresent(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func size(of dir: URL) -> Int64 {
        guard
            let enumerator = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    static func isFile(_ url: URL?) -> Bool {
        guard let url else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
}
