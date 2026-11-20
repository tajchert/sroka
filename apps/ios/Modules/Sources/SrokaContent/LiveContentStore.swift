import Foundation
import GRDB
import OSLog
import SrokaCore
import SrokaDatabase
import SrokaNetwork
import Synchronization

/// Progress of a bulk download run ("Downloading 3 of 12").
public struct DownloadProgress: Sendable, Hashable {
    public var done: Int
    public var total: Int
    public var currentTitle: String?
}

/// Result of a bulk download run. `failure` is set when the run stopped early (no network, session expired,
/// device storage full); the user-initiated fetch turns it into `SyncEvent.fetchFailed`.
public struct DownloadRunResult: Sendable, Hashable {
    /// Packages this run fetched (not ones that were already current).
    public var downloaded: Int
    public var failure: SyncErrorKind?

    public init(downloaded: Int = 0, failure: SyncErrorKind? = nil) {
        self.downloaded = downloaded
        self.failure = failure
    }
}

/// Outcome of one item download, richer than the domain `DownloadResult` (Android `DownloadOutcome`).
enum DownloadOutcome: Sendable, Equatable {
    /// A package was fetched and installed by this call.
    case downloaded
    /// The installed package was already current.
    case alreadyCurrent
    case notReady
    case failed(RemoteFailure)
    /// The device is (nearly) out of storage: transient, never counted as an attempt.
    case storageFull
    /// The calling task was cancelled; the row was put back as it was.
    case cancelled

    var domain: DownloadResult {
        switch self {
        case .downloaded, .alreadyCurrent: .downloaded
        case .notReady: .notReady
        case .failed(let reason): .failed(reason)
        case .storageFull: .failed(.server)
        case .cancelled: .failed(.network)
        }
    }
}

/// Live `ContentStore` plus the download pipeline (DECISIONS A9; Android `ContentStoreImpl.kt` and
/// `ContentDownloadWorker.kt`): `contentUrls` → package download (no auth, 50 MiB cap) → safe install with
/// SHA-256 checks → atomic swap → FTS body → `content_files` DOWNLOADED in one transaction; then the thumbnail.
///
/// The entry points are plain async functions over foreground `URLSession` calls through `SrokaAPI`, so the app
/// can run them from a scene, a `BGProcessingTask` or a `BGContinuedProcessingTask`:
/// `runAutomaticDownloads(policy:progress:)`, `downloadAll(progress:)`, `fetch(itemId:)`, `evict()`,
/// `recoverInterrupted()`, `deleteFiles(itemIds:)`, `clearDownloads()`, `removeAllContent()`.
/// Downloads of the same item are serialized.
public final class LiveContentStore: ContentStore, Sendable {
    /// Free space below which no download starts (2 × the package cap).
    public static let minFreeBytes: Int64 = 100 * 1024 * 1024
    public static let parallelDownloads = 3
    static let maxThumbBytes: Int64 = 5 * 1024 * 1024
    static let pdfSniffBytes = 1024
    static let evictAfterMs: Int64 = 30 * 24 * 60 * 60 * 1000
    static let evictBatch = 500
    /// Signed URL answers that mean "expired or rejected": fetch fresh URLs once.
    static let urlExpiredStatuses: Set<Int> = [401, 403, 404, 410]
    private static let recoverKey = "#recover"
    private static let clearKey = "#clear"

    public let paths: ContentPaths
    private let database: AppDatabase
    private let api: any SrokaAPI
    private let wifiOnlyAPI: any SrokaAPI
    private let installer: PackageInstaller
    private let now: @Sendable () -> Date
    private let freeBytes: @Sendable () -> Int64
    private let onUnauthorized: @Sendable () async -> Void
    private let locks = KeyedLock()
    private let log = Logger(subsystem: "app.sroka", category: "content")

    private struct State {
        /// Bumped by `clearDownloads`/`removeAllContent`; downloads started earlier must not commit afterwards.
        var generation = 0
        var recovered = false
    }

    private let state = Mutex(State())

    /// - Parameters:
    ///   - api: the any-network client (user fetches, the reader, "Any network").
    ///   - wifiOnlyAPI: a client on `makeWifiOnlySession()` for the "Wi-Fi only" policy; defaults to `api`.
    ///   - freeBytes: free space on the content volume (test hook); defaults to the real volume.
    ///   - onUnauthorized: called on HTTP 401 from the API host (the session layer marks the session expired).
    public init(
        database: AppDatabase,
        api: any SrokaAPI,
        wifiOnlyAPI: (any SrokaAPI)? = nil,
        paths: ContentPaths,
        installer: PackageInstaller = PackageInstaller(),
        now: @escaping @Sendable () -> Date = { Date() },
        freeBytes: (@Sendable () -> Int64)? = nil,
        onUnauthorized: @escaping @Sendable () async -> Void = {}
    ) {
        self.database = database
        self.api = api
        self.wifiOnlyAPI = wifiOnlyAPI ?? api
        self.paths = paths
        self.installer = installer
        self.now = now
        self.freeBytes = freeBytes ?? { paths.availableBytes() }
        self.onUnauthorized = onUnauthorized
        paths.prepareAll()
    }

    /// The `HTTPSrokaAPI` session configuration with `allowsExpensiveNetworkAccess = false` ("Wi-Fi only").
    public static func makeWifiOnlySession() -> URLSession {
        let configuration = HTTPSrokaAPI.makeSession().configuration
        configuration.allowsExpensiveNetworkAccess = false
        return URLSession(configuration: configuration)
    }

    private var generation: Int { state.withLock { $0.generation } }
    private var nowMs: Int64 { Int64((now().timeIntervalSince1970 * 1000).rounded()) }

    // MARK: ContentStore

    public func observeOffline(itemId: String) -> AsyncStream<OfflineState> {
        let observation = database.observeOffline(itemId: itemId)
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in observation { continuation.yield(value) }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func articleHtml(itemId: String) async -> String? {
        guard let file = paths.articleHtml(itemId), ContentPaths.isFile(file) else { return nil }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    public func articlesDirectory() -> URL { paths.articles }

    public func downloadNow(itemId: String) async -> DownloadResult {
        await fetch(itemId: itemId)
    }

    public func pdfFile(itemId: String) async -> URL? {
        guard let file = paths.pdfFile(itemId) else { return nil }
        let current = try? await database.read { db -> Bool in
            guard let item = try ItemDao.item(db, id: itemId), item.kind == .pdf,
                let row = try ContentFileDao.get(db, itemId: itemId)
            else { return false }
            // A row for another content id is stale (the document was replaced on the server).
            return row.state == .downloaded && row.contentId == item.contentId
        }
        return current == true && ContentPaths.isFile(file) ? file : nil
    }

    public func storageUsageBytes() async -> Int64 { paths.usageBytes() }

    /// "Remove downloaded articles": every package and thumbnail; the FTS bodies and pending uploads stay.
    public func clearDownloads() async {
        await locks.withLock(Self.clearKey) {
            // In-flight downloads see the new generation before committing and clean up after themselves.
            self.state.withLock { $0.generation += 1 }
            self.paths.deleteDownloads()
            self.paths.prepareAll()
            _ = try? await self.database.write { db in try ContentFileDao.deleteAll(db) }
        }
    }

    // MARK: Entry points

    /// One item now, on any network (the reader, `SyncController.downloadItemNow`).
    public func fetch(itemId: String) async -> DownloadResult {
        await download(itemId: itemId, api: api).domain
    }

    /// Automatic downloads after a sync, honouring the policy: Manual queues nothing, Wi-Fi only uses the
    /// client that refuses expensive networks.
    public func runAutomaticDownloads(
        policy: DownloadPolicy, progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async -> DownloadRunResult {
        switch policy {
        case .manual: DownloadRunResult()
        case .wifiOnly: await runBatch(api: wifiOnlyAPI, progress: progress)
        case .anyNetwork: await runBatch(api: api, progress: progress)
        }
    }

    /// "Fetch new articles" / "Download all now": every eligible item, ignoring Wi-Fi only.
    public func downloadAll(progress: (@Sendable (DownloadProgress) -> Void)? = nil) async -> DownloadRunResult {
        await runBatch(api: api, progress: progress)
    }

    /// Eligible items not yet downloaded (for the settings row and the progress card).
    public func eligibleCount() async -> Int {
        (try? await database.read { db in try ContentFileDao.eligibleCount(db) }) ?? 0
    }

    /// A9 eviction, after each successful sync: packages of archived, non-favorite items archived more than
    /// 30 days ago and neither downloaded nor read since. The FTS body is kept.
    public func evict() async {
        let before = nowMs - Self.evictAfterMs
        while true {
            let ids =
                (try? await database.read { db in
                    try ContentFileDao.evictionCandidates(db, archivedBefore: before, limit: Self.evictBatch)
                }) ?? []
            var evicted = 0
            for id in ids {
                // Under the item lock, so a reader fetch cannot install a package between row and file removal.
                let removed = await locks.withLock(id) {
                    let removed =
                        (try? await self.database.write { db -> Bool in
                            // The full predicate again, in the delete's transaction: the item may have been
                            // downloaded, read, favorited or unarchived since the query.
                            guard try Self.isEvictable(db, itemId: id, before: before) else { return false }
                            try ContentFileDao.delete(db, itemId: id)
                            return true
                        }) ?? false
                    if removed { self.paths.deleteItemFiles(id) }
                    return removed
                }
                if removed { evicted += 1 }
            }
            if evicted == 0 { return }
        }
    }

    /// `ContentFileDao.evictionCandidates`' predicate for one item.
    private static func isEvictable(_ db: Database, itemId: String, before: Int64) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS (SELECT 1 FROM content_files cf JOIN items i ON i.id = cf.item_id
                WHERE cf.item_id = ? AND cf.state = 'DOWNLOADED' AND i.status = 'ARCHIVED' AND i.is_favorite = 0
                  AND i.archived_at IS NOT NULL AND i.archived_at < ?
                  AND (cf.downloaded_at IS NULL OR cf.downloaded_at < ?)
                  AND (i.last_read_at IS NULL OR i.last_read_at < ?))
                """,
            arguments: [itemId, before, before, before]) ?? false
    }

    /// Deletes the files of items that were removed (sync tombstones, local delete, full-resync sweep).
    public func deleteFiles(itemIds: [String]) {
        for id in itemIds { paths.deleteItemFiles(id) }
    }

    /// Sign-out wipe: every file, pending uploads included, and no download of before may commit.
    public func removeAllContent() async {
        await locks.withLock(Self.clearKey) {
            self.state.withLock { $0.generation += 1 }
            self.paths.deleteEverything()
            _ = try? await self.database.write { db in try ContentFileDao.deleteAll(db) }
            self.paths.prepareAll()
        }
    }

    /// Once per launch, before any download: DOWNLOADING rows of a dead process go back to QUEUED, DOWNLOADED
    /// rows whose files are gone are dropped (an interrupted swap is rolled back first), thumbnails that
    /// vanished are cleared for a re-fetch, and files without any row are deleted.
    public func recoverInterrupted() async {
        if state.withLock({ $0.recovered }) { return }
        await locks.withLock(Self.recoverKey) {
            if self.state.withLock({ $0.recovered }) { return }
            // A failed or cancelled pass (database suspended, push out of time) is tried again by the next caller.
            guard await self.recover() else { return }
            self.state.withLock { $0.recovered = true }
        }
    }

    // MARK: Recovery

    /// False when a database write failed, so the reconciliation did not complete.
    private func recover() async -> Bool {
        guard
            let rows = try? await database.write({ db -> [ContentFileRecord] in
                try ContentFileDao.resetDownloading(db)
                return try ContentFileDao.all(db)
            })
        else { return false }
        var missing: [String] = []
        var staleThumbs: [ContentFileRecord] = []
        for row in rows {
            // The swap runs while the row is DOWNLOADING (now QUEUED): roll back for every row, before the sweep.
            rollBackInterruptedSwap(row.itemId)
            if row.state == .downloaded {
                if !isValidItemId(row.itemId) {
                    missing.append(row.itemId)
                    continue
                }
                if !hasLocalContent(row.itemId) {
                    missing.append(row.itemId)
                    continue
                }
            }
            if let thumb = row.thumbPath, !ContentPaths.isFile(paths.resolve(storedPath: thumb)) {
                staleThumbs.append(row)
            }
        }
        if !missing.isEmpty || !staleThumbs.isEmpty {
            log.notice("reconcile: \(missing.count) packages and \(staleThumbs.count) thumbnails missing")
            do {
                try await database.write { [missing, staleThumbs] db in
                    try ContentFileDao.delete(db, itemIds: missing)
                    for var row in staleThumbs {
                        row.thumbPath = nil
                        row.thumbAttempts = 0
                        try ContentFileDao.upsert(db, row)
                    }
                }
            } catch {
                return false
            }
            for id in missing { paths.deleteItemFiles(id) }
        }
        let known = Set(rows.map(\.itemId)).subtracting(missing)
        sweepOrphans(known: known)
        return true
    }

    /// Crash between "target → .old" and ".tmp → target": put the old package back.
    private func rollBackInterruptedSwap(_ itemId: String) {
        guard let dir = paths.articleDir(itemId), let old = paths.oldDir(itemId) else { return }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: dir.path), fileManager.fileExists(atPath: old.path) {
            try? fileManager.moveItem(at: old, to: dir)
        }
    }

    /// Leftovers no row points at: partial `.tmp`/`.old` entries, packages and thumbnails of items whose row is
    /// gone. Runs before this process starts any download, so nothing here is in use.
    private func sweepOrphans(known: Set<String>) {
        let fileManager = FileManager.default
        for url in (try? fileManager.contentsOfDirectory(at: paths.articles, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent
            if name.hasSuffix(ContentPaths.tmpSuffix) || name.hasSuffix(ContentPaths.oldSuffix) || !known.contains(name)
            {
                paths.removeIfPresent(url)
            }
        }
        for url in (try? fileManager.contentsOfDirectory(at: paths.thumbs, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent
            if !name.hasSuffix(".webp") || !known.contains(String(name.dropLast(5))) { paths.removeIfPresent(url) }
        }
        paths.removeIfPresent(paths.downloads)
        try? paths.prepare(paths.downloads)
    }

    private func hasLocalContent(_ itemId: String) -> Bool {
        ContentPaths.isFile(paths.articleHtml(itemId)) || ContentPaths.isFile(paths.pdfFile(itemId))
    }

    // MARK: Bulk run

    private final class RunState: Sendable {
        struct Values {
            var done = 0
            var downloaded = 0
            var failure: SyncErrorKind?
            var storageFull = false
            var stopped: Bool { failure != nil || storageFull }
        }

        let values = Mutex(Values())
    }

    private func runBatch(
        api: any SrokaAPI, progress: (@Sendable (DownloadProgress) -> Void)?
    ) async -> DownloadRunResult {
        await recoverInterrupted()
        let generation = generation
        let ids =
            (try? await database.read { db -> [String] in
                let rows = try ContentFileDao.eligibleForDownload(db) + ContentFileDao.thumbsToRetry(db)
                var seen = Set<String>()
                return rows.map(\.itemId).filter { seen.insert($0).inserted }
            }) ?? []
        let total = ids.count
        if total == 0 { return DownloadRunResult() }
        progress?(DownloadProgress(done: 0, total: total, currentTitle: nil))
        let run = RunState()
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func addNext() {
                guard next < ids.count else { return }
                let id = ids[next]
                next += 1
                group.addTask {
                    await self.batchStep(
                        itemId: id, total: total, generation: generation, api: api, run: run, progress: progress)
                }
            }
            for _ in 0..<min(Self.parallelDownloads, ids.count) { addNext() }
            for await _ in group { addNext() }
        }
        let values = run.values.withLock { $0 }
        return DownloadRunResult(downloaded: values.downloaded, failure: values.storageFull ? .storage : values.failure)
    }

    private func batchStep(
        itemId: String, total: Int, generation: Int, api: any SrokaAPI, run: RunState,
        progress: (@Sendable (DownloadProgress) -> Void)?
    ) async {
        if run.values.withLock({ $0.stopped }) || Task.isCancelled { return }
        // "Remove downloaded articles" ran meanwhile: do not re-fetch what the user cleared.
        if self.generation != generation { return }
        let outcome = await download(itemId: itemId, api: api, generation: generation)
        let title = try? await database.read { db -> String? in
            guard let item = try ItemDao.item(db, id: itemId) else { return nil }
            if let title = item.title, !title.isEmpty { return title }
            return displayDomain(item.url)
        }
        let done = run.values.withLock { values -> Int in
            values.done += 1
            switch outcome {
            case .downloaded: values.downloaded += 1
            case .alreadyCurrent, .notReady: break
            case .storageFull: values.storageFull = true
            case .failed(.network), .cancelled: values.failure = values.failure ?? .network
            case .failed(.unauthorized): values.failure = .auth
            case .failed: break
            }
            return values.done
        }
        progress?(DownloadProgress(done: done, total: total, currentTitle: title ?? nil))
    }

    // MARK: One item

    /// `generation`: the one a bulk run started under (a clear since then must stop it); nil = now.
    func download(itemId: String, api: any SrokaAPI, generation: Int? = nil) async -> DownloadOutcome {
        guard isValidItemId(itemId) else { return .failed(.server) }
        await recoverInterrupted()
        let generation = generation ?? self.generation
        return await locks.withLock(itemId) {
            await self.downloadLocked(itemId: itemId, generation: generation, api: api)
        }
    }

    private func downloadLocked(itemId: String, generation: Int, api: any SrokaAPI) async -> DownloadOutcome {
        if self.generation != generation { return .notReady }
        guard
            let snapshot = try? await database.read({ db -> (ItemRecord?, ContentFileRecord?) in
                (try ItemDao.item(db, id: itemId), try ContentFileDao.get(db, itemId: itemId))
            }),
            let item = snapshot.0
        else { return .failed(.server) }
        guard let contentId = item.contentId else { return .notReady }
        let previous = snapshot.1
        if item.kind == .pdf {
            return await downloadPdf(
                item: item, contentId: contentId, previous: previous, generation: generation, api: api)
        }
        if let previous, previous.state == .downloaded, previous.contentId == contentId,
            ContentPaths.isFile(paths.articleHtml(itemId))
        {
            await retryMissingThumbnail(item: item, row: previous, generation: generation, api: api)
            return .alreadyCurrent
        }
        if freeBytes() < Self.minFreeBytes { return .storageFull }

        let urls: ContentUrlsDto
        switch await contentUrls(itemId: itemId, api: api) {
        case .success(let value): urls = value
        case .failure(let failure):
            switch failure {
            case .notReady: return .notReady
            case .cancelled: return .cancelled
            case .network: return .failed(.network)
            case .unauthorized: return .failed(.unauthorized)
            case .http(let code, let reason):
                await markFailed(previous, itemId: itemId, contentId: contentId, error: code, generation: generation)
                return .failed(reason)
            }
        }

        guard await markDownloading(previous, itemId: itemId, contentId: contentId, generation: generation) else {
            return .notReady
        }
        guard let zip = paths.packageZip(itemId) else { return .failed(.server) }
        let outcome = await fetchAndInstall(
            itemId: itemId, contentId: contentId, packageUrl: urls.packageUrl, zip: zip, previous: previous,
            generation: generation, api: api)
        paths.removeIfPresent(zip)
        if outcome == .downloaded, let key = item.leadImageKey {
            await downloadThumbnail(itemId: itemId, baseUrl: urls.baseUrl, key: key, generation: generation, api: api)
        }
        return outcome
    }

    private func fetchAndInstall(
        itemId: String, contentId: String, packageUrl: String, zip: URL, previous: ContentFileRecord?,
        generation: Int, api: any SrokaAPI
    ) async -> DownloadOutcome {
        switch await fetchFile(packageUrl, to: zip, cap: PackageInstaller.maxTotalBytes, api: api) {
        case .ok: break
        case .tooLarge:
            await markFailed(previous, itemId: itemId, contentId: contentId, error: "too_large", generation: generation)
            return .failed(.server)
        case .http(let status):
            await markFailed(
                previous, itemId: itemId, contentId: contentId, error: "http_\(status)", generation: generation)
            return .failed(.server)
        case .badUrl:
            await markFailed(previous, itemId: itemId, contentId: contentId, error: "bad_url", generation: generation)
            return .failed(.server)
        case .network:
            await restore(previous, itemId: itemId, generation: generation)
            return .failed(.network)
        case .diskFull:
            await restore(previous, itemId: itemId, generation: generation)
            return .storageFull
        case .cancelled:
            await restore(previous, itemId: itemId, generation: generation)
            return .cancelled
        }

        let bytes: Int64
        switch installer.install(zip: zip, articlesDirectory: paths.articles, itemId: itemId) {
        case .invalid(let reason):
            log.notice("package rejected: \(reason, privacy: .public)")
            await markFailed(previous, itemId: itemId, contentId: contentId, error: reason, generation: generation)
            return .failed(.server)
        case .ioError:
            // Local I/O trouble (typically a full disk) is not the package's fault: no attempt counted.
            await restore(previous, itemId: itemId, generation: generation)
            return .storageFull
        case .installed(let installed):
            bytes = installed
        }

        let html = paths.articleHtml(itemId).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let body = HtmlText.extract(html)
        let downloadedAt = nowMs
        let committed = try? await database.write { db -> Bool in
            guard self.generation == generation else { return false }
            // Re-checks that the item still exists with this content id and the row is still ours.
            guard
                try ContentFileDao.commitDownloaded(
                    db, itemId: itemId, contentId: contentId, bytes: bytes, downloadedAt: downloadedAt)
            else { return false }
            if var row = try ContentFileDao.get(db, itemId: itemId), row.attempts != 0 {
                row.attempts = 0
                try ContentFileDao.upsert(db, row)
            }
            try ItemDao.setFtsBody(db, itemId: itemId, body: body)
            return true
        }
        return await settleCommit(committed, itemId: itemId)
    }

    // MARK: PDF items

    /// `documentUrl` → `articles/{id}.tmp` → `%PDF-` + size check → `articles/{id}/document.pdf` → DOWNLOADED.
    /// A 401/403/404/410 on the signed URL re-fetches the URLs once. No FTS body.
    private func downloadPdf(
        item: ItemRecord, contentId: String, previous: ContentFileRecord?, generation: Int, api: any SrokaAPI
    ) async -> DownloadOutcome {
        let itemId = item.id
        if let previous, previous.state == .downloaded, previous.contentId == contentId,
            ContentPaths.isFile(paths.pdfFile(itemId))
        {
            await retryMissingThumbnail(item: item, row: previous, generation: generation, api: api)
            return .alreadyCurrent
        }
        if freeBytes() < Self.minFreeBytes { return .storageFull }
        guard await markDownloading(previous, itemId: itemId, contentId: contentId, generation: generation),
            let temp = paths.tmpDir(itemId)
        else { return .notReady }
        defer { paths.removeIfPresent(temp) }

        var refreshed = false
        while true {
            let urls: ContentUrlsDto
            switch await contentUrls(itemId: itemId, api: api) {
            case .success(let value): urls = value
            case .failure(let failure):
                switch failure {
                case .http(let code, let reason):
                    await markFailed(
                        previous, itemId: itemId, contentId: contentId, error: code, generation: generation)
                    return .failed(reason)
                case .notReady:
                    await restore(previous, itemId: itemId, generation: generation)
                    return .notReady
                case .network:
                    await restore(previous, itemId: itemId, generation: generation)
                    return .failed(.network)
                case .unauthorized:
                    await restore(previous, itemId: itemId, generation: generation)
                    return .failed(.unauthorized)
                case .cancelled:
                    await restore(previous, itemId: itemId, generation: generation)
                    return .cancelled
                }
            }
            guard let documentUrl = urls.documentUrl else {
                await markFailed(
                    previous, itemId: itemId, contentId: contentId, error: "no_document_url", generation: generation)
                return .failed(.server)
            }
            switch await fetchFile(documentUrl, to: temp, cap: Limits.maxPdfBytes, api: api) {
            case .ok: break
            case .tooLarge:
                await markFailed(
                    previous, itemId: itemId, contentId: contentId, error: "too_large", generation: generation)
                return .failed(.server)
            case .http(let status):
                if !refreshed, Self.urlExpiredStatuses.contains(status) {
                    // Signed URL expired or rejected: ask for fresh ones once.
                    refreshed = true
                    continue
                }
                await markFailed(
                    previous, itemId: itemId, contentId: contentId, error: "http_\(status)", generation: generation)
                return .failed(.server)
            case .badUrl:
                await markFailed(
                    previous, itemId: itemId, contentId: contentId, error: "bad_url", generation: generation)
                return .failed(.server)
            case .network:
                await restore(previous, itemId: itemId, generation: generation)
                return .failed(.network)
            case .diskFull:
                await restore(previous, itemId: itemId, generation: generation)
                return .storageFull
            case .cancelled:
                await restore(previous, itemId: itemId, generation: generation)
                return .cancelled
            }
            guard Self.looksLikePdf(temp) else {
                await markFailed(
                    previous, itemId: itemId, contentId: contentId, error: "not_pdf", generation: generation)
                return .failed(.server)
            }
            let bytes = ContentPaths.fileSize(temp)
            let downloadedAt = nowMs
            guard let dir = paths.articleDir(itemId), let dest = paths.pdfFile(itemId) else { return .failed(.server) }
            let committed = try? await database.write { db -> Bool in
                guard self.generation == generation, let current = try ItemDao.item(db, id: itemId),
                    current.contentId == contentId,
                    let row = try ContentFileDao.get(db, itemId: itemId), row.state == .downloading,
                    row.contentId == contentId
                else { return false }
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: temp, to: dest)
                var done = row
                done.state = .downloaded
                done.bytes = bytes
                done.attempts = 0
                done.error = nil
                done.downloadedAt = downloadedAt
                try ContentFileDao.upsert(db, done)
                return true
            }
            let settled = await settleCommit(committed, itemId: itemId)
            if settled != .downloaded { return settled }
            if let key = item.leadImageKey {
                await downloadThumbnail(
                    itemId: itemId, baseUrl: urls.baseUrl, key: key, generation: generation, api: api)
            }
            return .downloaded
        }
    }

    /// After the commit transaction: false = cleared or deleted meanwhile, nil = the write itself failed (disk
    /// full, rename error). Either way no files stay without a row; a failed write also drops the DOWNLOADING
    /// row so the item is eligible again, without counting an attempt.
    private func settleCommit(_ committed: Bool?, itemId: String) async -> DownloadOutcome {
        if committed == true { return .downloaded }
        paths.deleteItemFiles(itemId)
        if committed == nil {
            _ = try? await database.write { db in try ContentFileDao.delete(db, itemId: itemId) }
            return .storageFull
        }
        return .notReady
    }

    /// `%PDF-` within the first KiB.
    static func looksLikePdf(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: pdfSniffBytes), !head.isEmpty else { return false }
        return head.range(of: Data("%PDF-".utf8)) != nil
    }

    // MARK: Thumbnails

    /// Best effort: a DOWNLOADED row whose thumbnail never arrived gets another try (capped).
    private func retryMissingThumbnail(
        item: ItemRecord, row: ContentFileRecord, generation: Int, api: any SrokaAPI
    ) async {
        guard let key = item.leadImageKey, row.thumbAttempts < ContentFileDao.maxThumbAttempts else { return }
        if let path = row.thumbPath, ContentPaths.isFile(paths.resolve(storedPath: path)) { return }
        switch await contentUrls(itemId: item.id, api: api) {
        case .success(let urls):
            await downloadThumbnail(itemId: item.id, baseUrl: urls.baseUrl, key: key, generation: generation, api: api)
        case .failure(.http), .failure(.notReady):
            await bumpThumbAttempts(item.id, generation: generation)
        case .failure:
            break
        }
    }

    /// Non-fatal: the list simply shows no image. Downloads to a temp file and moves it into place inside the
    /// transaction that confirms the item and its row still exist, so nothing is orphaned.
    private func downloadThumbnail(itemId: String, baseUrl: String, key: String, generation: Int, api: any SrokaAPI)
        async
    {
        guard PackageInstaller.safeRelativePath(key) != nil, let temp = paths.thumbTemp(itemId),
            let dest = paths.thumb(itemId)
        else { return }
        defer { paths.removeIfPresent(temp) }
        var base = baseUrl
        while base.hasSuffix("/") { base.removeLast() }
        switch await fetchFile(base + "/" + key, to: temp, cap: Self.maxThumbBytes, api: api) {
        case .ok: break
        // A blip is retried later without counting; anything else counts toward the cap.
        case .network, .cancelled, .diskFull: return
        case .tooLarge, .http, .badUrl:
            await bumpThumbAttempts(itemId, generation: generation)
            return
        }
        let thumbs = paths.thumbs
        _ = try? await database.write { db -> Bool in
            guard self.generation == generation, try ItemDao.item(db, id: itemId) != nil,
                var row = try ContentFileDao.get(db, itemId: itemId)
            else { return false }
            try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: temp, to: dest)
            row.thumbPath = ContentPaths.thumbRelativePath(itemId)
            try ContentFileDao.upsert(db, row)
            return true
        }
    }

    private func bumpThumbAttempts(_ itemId: String, generation: Int) async {
        _ = try? await database.write { db in
            guard self.generation == generation, var row = try ContentFileDao.get(db, itemId: itemId) else { return }
            row.thumbAttempts += 1
            try ContentFileDao.upsert(db, row)
        }
    }

    // MARK: Rows

    private func markDownloading(_ previous: ContentFileRecord?, itemId: String, contentId: String, generation: Int)
        async -> Bool
    {
        let sameContent = previous?.contentId == contentId
        return await writeRow(
            ContentFileRecord(
                itemId: itemId,
                contentId: contentId,
                state: .downloading,
                bytes: previous?.bytes ?? 0,
                attempts: sameContent ? previous?.attempts ?? 0 : 0,
                downloadedAt: previous?.downloadedAt,
                thumbPath: previous?.thumbPath,
                thumbAttempts: previous?.thumbAttempts ?? 0
            ),
            generation: generation
        )
    }

    private func markFailed(
        _ previous: ContentFileRecord?, itemId: String, contentId: String, error: String, generation: Int
    ) async {
        let attempts = previous.map { $0.contentId == contentId ? $0.attempts + 1 : 1 } ?? 1
        await writeRow(
            ContentFileRecord(
                itemId: itemId,
                contentId: contentId,
                state: .failed,
                bytes: previous?.bytes ?? 0,
                attempts: attempts,
                error: error,
                downloadedAt: previous?.downloadedAt,
                thumbPath: previous?.thumbPath,
                thumbAttempts: previous?.thumbAttempts ?? 0
            ),
            generation: generation
        )
    }

    /// Puts the row back as it was before this attempt (transient failures are not attempts).
    private func restore(_ previous: ContentFileRecord?, itemId: String, generation: Int) async {
        if let previous {
            await writeRow(previous, generation: generation)
        } else {
            _ = try? await database.write { db in try ContentFileDao.delete(db, itemId: itemId) }
        }
    }

    /// Upserts unless the item was deleted or downloads were cleared meanwhile; false = not written.
    @discardableResult
    private func writeRow(_ row: ContentFileRecord, generation: Int) async -> Bool {
        (try? await database.write { db -> Bool in
            guard self.generation == generation, try ItemDao.item(db, id: row.itemId) != nil else { return false }
            try ContentFileDao.upsert(db, row)
            return true
        }) ?? false
    }

    // MARK: Network

    private enum UrlsFailure: Error {
        /// 409: not parsed yet. Not an attempt.
        case notReady
        case network
        case unauthorized
        case cancelled
        /// Any other answer: counts as an attempt (`code` is stored in `content_files.error`).
        case http(code: String, reason: RemoteFailure)
    }

    private func contentUrls(itemId: String, api: any SrokaAPI) async -> Result<ContentUrlsDto, UrlsFailure> {
        do {
            return .success(try await api.contentUrls(itemId: itemId))
        } catch let error as ApiError {
            switch error {
            case .transport: return .failure(.network)
            case .http(let status, _, _, _):
                if status == 409 { return .failure(.notReady) }
                if status == 401 {
                    await onUnauthorized()
                    return .failure(.unauthorized)
                }
                return .failure(.http(code: "http_\(status)", reason: error.remoteFailure))
            case .malformedResponse, .invalidRequest:
                return .failure(.http(code: "malformed", reason: .server))
            }
        } catch {
            return .failure(.cancelled)
        }
    }

    enum FetchResult: Sendable, Equatable {
        case ok
        case tooLarge
        case http(Int)
        case badUrl
        case network
        case diskFull
        case cancelled
    }

    /// Downloads a signed content URL (no auth header) to `destination`, aborting above `cap` bytes.
    func fetchFile(_ urlString: String, to destination: URL, cap: Int64, api: any SrokaAPI) async -> FetchResult {
        guard let url = URL(string: urlString) else { return .badUrl }
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let exceeded = Mutex(false)
        let holder = Mutex<Task<Void, any Error>?>(nil)
        let task = Task {
            try await api.download(from: url, to: destination) { done, total in
                if done > cap || total > cap {
                    exceeded.withLock { $0 = true }
                    holder.withLock { $0?.cancel() }
                }
            }
        }
        holder.withLock { $0 = task }
        let result: FetchResult
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            result = ContentPaths.fileSize(destination) > cap ? .tooLarge : .ok
        } catch let error as ApiError {
            switch error {
            case .http(let status, _, _, _): result = .http(status)
            case .transport(let code):
                result = exceeded.withLock { $0 } ? .tooLarge : Self.isDiskFull(code) ? .diskFull : .network
            case .invalidRequest: result = .badUrl
            case .malformedResponse: result = .network
            }
        } catch {
            result = exceeded.withLock { $0 } ? .tooLarge : .cancelled
        }
        if result != .ok { paths.removeIfPresent(destination) }
        return result
    }

    private static func isDiskFull(_ code: URLError.Code) -> Bool {
        code == .cannotWriteToFile || code == .cannotCreateFile
    }
}
