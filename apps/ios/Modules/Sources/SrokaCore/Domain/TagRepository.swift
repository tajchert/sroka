import Dependencies

/// Tags across the library (local-first like `LibraryRepository`). Android: TagRepository.kt.
public protocol TagRepository: Sendable {
    /// All tags with live-item counts, sorted case-insensitively by name.
    func observeTags() -> AsyncStream<[TagCount]>

    /// Most recently used tag names (newest first), for tag-entry suggestions.
    func observeRecentTags(limit: Int) -> AsyncStream<[String]>

    /// Renames `from` to `to` everywhere; merges into an existing tag with the same key.
    func rename(from: String, to: String) async -> TagEditResult

    /// Removes the tag from every item.
    func delete(name: String) async
}

extension TagRepository {
    public func observeRecentTags() -> AsyncStream<[String]> { observeRecentTags(limit: Limits.recentTagsLimit) }
}

public enum TagEditResult: Sendable, Hashable {
    case done
    /// Empty after normalization or longer than `Limits.maxTagLength` characters.
    case invalidName
}

private struct UnimplementedTagRepository: TagRepository {
    private func fail(_ method: String) { reportUnimplemented("TagRepository.\(method)", key: "tagRepository") }

    func observeTags() -> AsyncStream<[TagCount]> {
        fail("observeTags")
        return .finished
    }
    func observeRecentTags(limit: Int) -> AsyncStream<[String]> {
        fail("observeRecentTags")
        return .finished
    }
    func rename(from: String, to: String) async -> TagEditResult {
        fail("rename")
        return .invalidName
    }
    func delete(name: String) async { fail("delete") }
}

private enum TagRepositoryKey: TestDependencyKey {
    static let testValue: any TagRepository = UnimplementedTagRepository()
}

extension DependencyValues {
    public var tagRepository: any TagRepository {
        get { self[TagRepositoryKey.self] }
        set { self[TagRepositoryKey.self] = newValue }
    }
}
