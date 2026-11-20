import Dependencies
import Foundation
import Observation
import SrokaCore

/// Model of the tag editor sheet for one item. The app root presents it for the library, the reader
/// and the share extension (`TagEditorSheet(model:)`); `onFinish` runs after Save or Cancel so the
/// root can dismiss the sheet (async, so tests await the whole flow).
///
/// Attach with `.task { model.start() }` (observation stops on `stop()` or deinit).
@MainActor
@Observable
public final class TagEditorViewModel {
    @ObservationIgnored @Dependency(\.libraryRepository) private var library
    @ObservationIgnored @Dependency(\.tagRepository) private var tagRepository

    public let itemId: String
    /// Tags currently on the item in the editor (not saved until `saveTapped()`).
    public private(set) var tags: [String] = []
    /// Text typed but not yet added; a tag name is at most `Limits.maxTagLength` characters.
    public var draft = "" {
        didSet {
            if draft.count > Limits.maxTagLength { draft = String(draft.prefix(Limits.maxTagLength)) }
            if draft != oldValue { recomputeSuggestions() }
        }
    }
    /// "Create x" chip and the matching known tags under the field.
    public private(set) var suggestionChips: [TagSuggestionChip] = []
    /// False until the item's current tags are loaded (Save stays disabled).
    public private(set) var isLoaded = false
    public private(set) var isSaving = false
    /// The item vanished (deleted by a sync) while the editor was open.
    public private(set) var itemIsGone = false

    @ObservationIgnored private let onFinish: @MainActor () async -> Void
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    private var initialTags: [String] = []
    private var known: [String] = []

    /// - Parameter onFinish: called after Save or Cancel (dismiss the sheet here).
    public init(itemId: String, onFinish: @escaping @MainActor () async -> Void = {}) {
        self.itemId = itemId
        self.onFinish = onFinish
    }

    isolated deinit {
        for task in tasks { task.cancel() }
    }

    /// No more tags can be added to this item.
    public var isAtLimit: Bool { tags.count >= Limits.maxTagsPerItem }

    public var canSave: Bool { isLoaded && !isSaving && !itemIsGone }

    /// Loads the item's tags and observes the suggestions. Idempotent; the view calls it from `.task`.
    public func start() {
        guard tasks.isEmpty else { return }
        let itemStream = library.observeItem(id: itemId)
        let recentStream = tagRepository.observeRecentTags()
        tasks = [
            Task { [weak self] in
                for await item in itemStream {
                    guard let self else { return }
                    loaded(item)
                    return
                }
            },
            Task { [weak self] in
                for await names in recentStream {
                    guard let self else { return }
                    known = names
                    recomputeSuggestions()
                }
            },
        ]
    }

    public func stop() {
        for task in tasks { task.cancel() }
        tasks = []
    }

    /// The item's tags arrive once; later changes (a sync) must not overwrite the user's edits.
    private func loaded(_ item: Item?) {
        guard let item else {
            itemIsGone = true
            isLoaded = true
            return
        }
        tags = item.tags
        initialTags = item.tags
        isLoaded = true
        recomputeSuggestions()
    }

    // MARK: Intents

    /// Return key: adds the typed text as a tag.
    public func addDraftTapped() {
        tags = TagRules.add(tags, draft)
        draft = ""
        recomputeSuggestions()
    }

    /// A suggestion chip or the "Create x" chip.
    public func suggestionTapped(_ name: String) {
        tags = TagRules.add(tags, name)
        draft = ""
        recomputeSuggestions()
    }

    public func removeTapped(_ tag: String) {
        tags.removeAll { $0 == tag }
        recomputeSuggestions()
    }

    /// Saves the tags plus whatever is still typed in the field.
    public func saveTapped() async {
        guard canSave else { return }
        isSaving = true
        let names = TagRules.add(tags, draft)
        await library.setTags(id: itemId, names: names)
        isSaving = false
        await onFinish()
    }

    public func cancelTapped() async {
        await onFinish()
    }

    private func recomputeSuggestions() {
        let suggestions = TagSuggestions(draft: draft, tags: tags, known: known)
        var chips: [TagSuggestionChip] = []
        if let create = suggestions.create, !isAtLimit { chips.append(.create(create)) }
        if !isAtLimit { chips.append(contentsOf: suggestions.existing.map(TagSuggestionChip.existing)) }
        suggestionChips = chips
    }
}

/// One chip under the field.
public enum TagSuggestionChip: Sendable, Hashable, Identifiable {
    /// "Create “name”" for a new tag.
    case create(String)
    case existing(String)

    public var id: String {
        switch self {
        case .create(let name): "create:\(name)"
        case .existing(let name): "existing:\(name)"
        }
    }

    public var name: String {
        switch self {
        case .create(let name), .existing(let name): name
        }
    }
}
