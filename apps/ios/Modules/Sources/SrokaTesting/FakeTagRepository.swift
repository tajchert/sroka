import Foundation
import SrokaCore

/// In-memory `TagRepository` backed by a `FakeLibraryRepository`, so tag edits show up in the list.
public final class FakeTagRepository: TagRepository {
    public let library: FakeLibraryRepository

    public init(library: FakeLibraryRepository) {
        self.library = library
    }

    public func observeTags() -> AsyncStream<[TagCount]> {
        library.items.stream(Self.counts)
    }

    public func observeRecentTags(limit: Int) -> AsyncStream<[String]> {
        library.items.stream { items in
            var seen = Set<String>()
            var recent: [String] = []
            for item in items.sorted(by: { $0.savedAt > $1.savedAt }) {
                for tag in item.tags where seen.insert(tagKey(tag)).inserted { recent.append(tag) }
            }
            return Array(recent.prefix(limit))
        }
    }

    public func rename(from: String, to: String) async -> TagEditResult {
        let name = normalizeTagName(to)
        guard !name.isEmpty, name.count <= Limits.maxTagLength else { return .invalidName }
        let fromKey = tagKey(from)
        library.items.update { items in
            for index in items.indices where items[index].tags.contains(where: { tagKey($0) == fromKey }) {
                let renamed = items[index].tags.map { tagKey($0) == fromKey ? name : $0 }
                items[index].tags = FakeLibraryRepository.normalizedTags(renamed)
            }
        }
        return .done
    }

    public func delete(name: String) async {
        let key = tagKey(name)
        library.items.update { items in
            for index in items.indices { items[index].tags.removeAll { tagKey($0) == key } }
        }
    }

    static func counts(_ items: [Item]) -> [TagCount] {
        var counts: [String: TagCount] = [:]
        for item in items {
            for tag in item.tags {
                counts[tagKey(tag), default: TagCount(name: tag, count: 0)].count += 1
            }
        }
        return counts.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
