import GRDB
import SrokaCore
import SrokaDatabase

/// Tags across the library, local-first. Android: `TagRepositoryImpl`.
public struct LiveTagRepository: TagRepository {
    private let database: AppDatabase
    private let writer: OpWriter
    private let syncController: any SyncController

    public init(database: AppDatabase, writer: OpWriter, syncController: any SyncController) {
        self.database = database
        self.writer = writer
        self.syncController = syncController
    }

    public func observeTags() -> AsyncStream<[TagCount]> {
        AsyncStream.observing { [database] in database.observeTagCounts() }
    }

    public func observeRecentTags(limit: Int) -> AsyncStream<[String]> {
        AsyncStream.observing { [database] in database.observeRecentTags(limit: limit) }
    }

    public func rename(from: String, to: String) async -> TagEditResult {
        let target = normalizeTagName(to)
        if target.isEmpty || target.utf16.count > Limits.maxTagLength { return .invalidName }
        let source = normalizeTagName(from)
        if source.isEmpty || source == target { return .done }
        await write { _, context in [.tagRename(.init(opId: context.newId(), at: context.at, from: source, to: target))]
        }
        return .done
    }

    public func delete(name: String) async {
        let tag = normalizeTagName(name)
        if tag.isEmpty { return }
        await write { _, context in [.tagDelete(.init(opId: context.newId(), at: context.at, tag: tag))] }
    }

    private func write(_ build: @escaping @Sendable (Database, OpContext) throws -> [WireOp]) async {
        do {
            if try await writer.write(build) { syncController.requestSync() }
        } catch {
            syncLog.error("tag write failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}
