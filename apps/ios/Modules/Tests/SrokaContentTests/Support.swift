import CryptoKit
import Foundation
import GRDB
import SrokaCore
import SrokaDatabase
import SrokaNetwork
import Synchronization
import ZIPFoundation

@testable import SrokaContent

// MARK: Temp directories

/// A fresh directory under the system temp dir, removed by the caller with `cleanUp()`.
struct TempDir: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(
            path: "sroka-content-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appending(path: name, directoryHint: .notDirectory) }

    func cleanUp() { try? FileManager.default.removeItem(at: url) }
}

// MARK: Zip fixtures

enum ZipEntry {
    case file(String, Data)
    case directory(String)
    case symlink(String, target: String)
}

/// Builds a zip at `url` with exactly these entries, in order (duplicates and hostile names included).
func makeZip(at url: URL, _ entries: [ZipEntry]) throws {
    try? FileManager.default.removeItem(at: url)
    let archive = try Archive(url: url, accessMode: .create)
    for entry in entries {
        switch entry {
        case .file(let path, let data):
            try archive.addEntry(
                with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate
            ) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        case .directory(let path):
            try archive.addEntry(with: path, type: .directory, uncompressedSize: Int64(0)) { (_: Int64, _: Int) in
                Data()
            }
        case .symlink(let path, let target):
            let data = Data(target.utf8)
            try archive.addEntry(with: path, type: .symlink, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func manifest(_ files: [(String, Data)]) -> Data {
    let list = files.map { #"{"path":"\#($0.0)","sha256":"\#(sha256($0.1))"}"# }.joined(separator: ",")
    return Data(#"{"version":1,"files":[\#(list)]}"#.utf8)
}

/// A valid package: `article.html`, one image and a manifest listing both.
func validPackage(html: String = "<html><body><p>Hello &amp; welcome</p></body></html>") -> [ZipEntry] {
    let article = Data(html.utf8)
    let image = Data(repeating: 7, count: 300)
    return [
        .file("manifest.json", manifest([("article.html", article), ("img/a.webp", image)])),
        .file("article.html", article),
        .file("img/a.webp", image),
    ]
}

// MARK: Database

func item(
    _ id: String,
    contentId: String? = "c1",
    status: ItemStatus = .unread,
    favorite: Bool = false,
    savedAt: Int64 = 1_000,
    archivedAt: Int64? = nil,
    lastReadAt: Int64? = nil,
    leadImageKey: String? = nil,
    kind: ItemKind = .article,
    title: String? = nil
) -> ItemRecord {
    ItemRecord(
        id: id,
        url: "https://example.com/\(id)",
        canonicalUrl: "https://example.com/\(id)",
        title: title,
        leadImageKey: leadImageKey,
        contentId: contentId,
        parseStatus: .ok,
        status: status,
        isFavorite: favorite,
        progress: 0,
        savedAt: savedAt,
        archivedAt: archivedAt,
        lastReadAt: lastReadAt,
        kind: kind
    )
}

extension AppDatabase {
    func insert(_ items: ItemRecord...) throws {
        try writer.write { db in
            for item in items { try ItemDao.upsert(db, item) }
        }
    }

    func insert(_ row: ContentFileRecord) throws {
        try writer.write { db in try ContentFileDao.upsert(db, row) }
    }

    func row(_ itemId: String) throws -> ContentFileRecord? {
        try writer.read { db in try ContentFileDao.get(db, itemId: itemId) }
    }

    func ftsBody(_ itemId: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT f.body FROM items_fts f JOIN items i ON i.fts_rowid = f.rowid WHERE i.id = ?",
                arguments: [itemId])
        }
    }
}

// MARK: Fake API

func contentUrls(_ itemId: String, documentUrl: String? = nil) -> ContentUrlsDto {
    var json: [String: Any] = [
        "articleUrl": "https://content.test/\(itemId)/article.html",
        "baseUrl": "https://content.test/\(itemId)/",
        "packageUrl": "https://content.test/\(itemId)/package.zip",
        "expiresAt": 1,
    ]
    if let documentUrl { json["documentUrl"] = documentUrl }
    return decode(json)
}

func uploadResponse(itemId: String, created: Bool = true, leadImageKey: String? = nil) -> PdfUploadResponseDto {
    var item: [String: Any] = ["id": itemId, "url": "https://example.com/\(itemId).pdf", "kind": "pdf"]
    if let leadImageKey { item["leadImageKey"] = leadImageKey }
    return decode(["item": item, "created": created])
}

/// Decodes a DTO from a JSON object literal (the DTOs only have decoding initializers).
private func decode<T: Decodable>(_ json: [String: Any]) -> T {
    do {
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    } catch {
        fatalError("fixture does not decode: \(error)")
    }
}

func httpError(_ status: Int, _ code: String? = nil) -> ApiError {
    .http(status: status, code: code, message: nil, retryAfter: nil)
}

/// What the fake content host answers for one URL.
enum Served: Sendable {
    case file(URL)
    case data(Data)
    case error(ApiError)
    /// Reports `progress` bytes, then writes nothing (for the size-cap check).
    case progress(Int64)
}

final class FakeAPI: SrokaAPI, Sendable {
    private struct State {
        var urls: [String: [Result<ContentUrlsDto, ApiError>]] = [:]
        var served: [String: [Served]] = [:]
        var contentUrlCalls: [String] = []
        var downloads: [String] = []
        var uploads: [Result<PdfUploadResponseDto, ApiError>] = []
        var uploadCalls = 0
        var thumbnails: [(String, Int, String)] = []
    }

    private let state = Mutex(State())
    /// Runs inside `download` before the file is written (to race other work against a download).
    let onDownload = Mutex<(@Sendable (URL) async -> Void)?>(nil)
    /// Runs inside `uploadPdf` before it answers, with no progress reported (to hold a request open).
    let onUpload = Mutex<(@Sendable () async -> Void)?>(nil)

    /// Answers for `contentUrls(itemId)`, consumed in order; the last one repeats.
    func setUrls(_ itemId: String, _ answers: Result<ContentUrlsDto, ApiError>...) {
        state.withLock { $0.urls[itemId] = answers }
    }

    /// Answers for downloads of `url`, consumed in order; the last one repeats.
    func serve(_ url: String, _ answers: Served...) {
        state.withLock { $0.served[url] = answers }
    }

    func setUploads(_ answers: Result<PdfUploadResponseDto, ApiError>...) {
        state.withLock { $0.uploads = answers }
    }

    var contentUrlCalls: [String] { state.withLock { $0.contentUrlCalls } }
    var downloads: [String] { state.withLock { $0.downloads } }
    var uploadCalls: Int { state.withLock { $0.uploadCalls } }
    var thumbnailUploads: [(String, Int, String)] { state.withLock { $0.thumbnails } }

    private static func next<T>(_ queue: inout [T]) -> T? {
        guard let first = queue.first else { return nil }
        if queue.count > 1 { queue.removeFirst() }
        return first
    }

    func contentUrls(itemId: String) async throws -> ContentUrlsDto {
        let answer = state.withLock { state -> Result<ContentUrlsDto, ApiError>? in
            state.contentUrlCalls.append(itemId)
            return Self.next(&state.urls[itemId, default: []])
        }
        guard let answer else { throw httpError(404, "not_found") }
        return try answer.get()
    }

    func download(from url: URL, to destination: URL, onProgress: ByteProgress?) async throws {
        let answer = state.withLock { state -> Served? in
            state.downloads.append(url.absoluteString)
            return Self.next(&state.served[url.absoluteString, default: []])
        }
        if let hook = onDownload.withLock({ $0 }) { await hook(url) }
        try Task.checkCancellation()
        switch answer {
        case nil: throw httpError(404)
        case .error(let error): throw error
        case .file(let source):
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            let size = ContentPaths.fileSize(destination)
            onProgress?(size, size)
        case .data(let data):
            try data.write(to: destination)
            onProgress?(Int64(data.count), Int64(data.count))
        case .progress(let bytes):
            onProgress?(bytes, -1)
            try Task.checkCancellation()
            try Data(count: 10).write(to: destination)
        }
    }

    func uploadPdf(
        file: URL, fileName: String, tags: [String], source: ItemSource, onProgress: ByteProgress?
    ) async throws -> PdfUploadResponseDto {
        let answer = state.withLock { state -> Result<PdfUploadResponseDto, ApiError>? in
            state.uploadCalls += 1
            return Self.next(&state.uploads)
        }
        if let hook = onUpload.withLock({ $0 }) { await hook() }
        guard let answer else { throw httpError(500) }
        onProgress?(1, 1)
        return try answer.get()
    }

    func uploadThumbnail(itemId: String, data: Data, contentType: String) async throws -> ItemDto {
        state.withLock { $0.thumbnails.append((itemId, data.count, contentType)) }
        throw ApiError.malformedResponse
    }

    func sendOtp(email: String) async throws { throw ApiError.invalidRequest }
    func signIn(email: String, otp: String) async throws -> SignInResult { throw ApiError.invalidRequest }
    func signOut() async throws { throw ApiError.invalidRequest }
    func push(payloads: [String]) async throws -> PushResponseDto { throw ApiError.invalidRequest }
    func pull(cursor: Int64, limit: Int, full: Bool) async throws -> PullResponseDto { throw ApiError.invalidRequest }
    func item(id: String) async throws -> ItemDto { throw ApiError.invalidRequest }
    func me() async throws -> MeDto { throw ApiError.invalidRequest }
    func deleteAccount() async throws { throw ApiError.invalidRequest }
    func createImport(source: URL, fileName: String, mimeType: String, format: ImportFormat) async throws -> JobDto {
        throw ApiError.invalidRequest
    }
    func importJob(id: String) async throws -> JobDto { throw ApiError.invalidRequest }
    func export(format: ExportFormat, to destination: URL) async throws -> ExportFile { throw ApiError.invalidRequest }
    func config() async throws -> ConfigDto { throw ApiError.invalidRequest }
}

// MARK: Store harness

/// An in-memory database, a temp content root, a fake API and a store over them.
final class Harness {
    let dir: TempDir
    let database: AppDatabase
    let api = FakeAPI()
    let paths: ContentPaths
    /// The store's fixed clock: day 100 of the epoch.
    static let now = Date(timeIntervalSince1970: 100 * 24 * 60 * 60)
    let store: LiveContentStore

    init(installer: PackageInstaller = PackageInstaller(), freeBytes: Int64 = .max) throws {
        dir = try TempDir()
        database = try AppDatabase.inMemory()
        paths = ContentPaths(root: dir.url.appending(path: "Content", directoryHint: .isDirectory))
        store = LiveContentStore(
            database: database, api: api, paths: paths, installer: installer,
            now: { Harness.now }, freeBytes: { freeBytes })
    }

    var nowMs: Int64 { Int64(Self.now.timeIntervalSince1970 * 1000) }

    /// Serves a valid package for `itemId` (and its URLs).
    func servePackage(_ itemId: String, _ entries: [ZipEntry] = validPackage()) throws {
        let zip = dir.file("\(itemId)-\(UUID().uuidString).zip")
        try makeZip(at: zip, entries)
        api.setUrls(itemId, .success(contentUrls(itemId)))
        api.serve("https://content.test/\(itemId)/package.zip", .file(zip))
    }
}
