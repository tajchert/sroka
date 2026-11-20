import Dependencies
import Foundation
import Observation
import SrokaCore

/// Model of the Tags tab: the tag list with counts, rename, delete with confirmation, and the push
/// to one tag's items (`openedTag`). Other features' screens are requested through `onIntent`.
/// Attach with `.task { model.start() }`.
@MainActor
@Observable
public final class TagsViewModel {
    @ObservationIgnored @Dependency(\.tagRepository) private var tagRepository
    @ObservationIgnored @Dependency(\.authRepository) private var authRepository

    /// All tags with live-item counts, sorted by name; nil while loading.
    public private(set) var tags: [TagCount]?
    /// First letter of the signed-in email for the avatar button.
    public private(set) var avatarLetter = "?"

    /// The tag whose items are pushed (set by `tagTapped`; the navigation stack clears it on back).
    public var openedTag: TagItemsViewModel?

    // Rename
    public var isRenaming = false
    public private(set) var renamingTag: String?
    public var renameText = "" {
        didSet { if renameText != oldValue { isRenameInvalid = false } }
    }
    public private(set) var isRenameInvalid = false

    // Delete
    public var isConfirmingDelete = false
    public private(set) var tagPendingDeletion: String?
    /// Haptic trigger (`sensoryFeedback`): warning on delete.
    public private(set) var warningFeedbackCount = 0

    @ObservationIgnored public var onIntent: @MainActor (TagsIntent) -> Void
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    public init(onIntent: @escaping @MainActor (TagsIntent) -> Void = { _ in }) {
        self.onIntent = onIntent
    }

    isolated deinit {
        for task in tasks { task.cancel() }
    }

    /// Starts observing the repositories. Idempotent; the view calls it from `.task`.
    public func start() {
        guard tasks.isEmpty else { return }
        let tagStream = tagRepository.observeTags()
        let sessionStream = authRepository.session
        tasks = [
            Task { [weak self] in
                for await tags in tagStream {
                    guard let self else { return }
                    self.tags = tags
                }
            },
            Task { [weak self] in
                for await session in sessionStream {
                    guard let self else { return }
                    avatarLetter = Self.avatarLetter(for: session)
                }
            },
        ]
    }

    public func stop() {
        for task in tasks { task.cancel() }
        tasks = []
    }

    static func avatarLetter(for session: SessionState) -> String {
        guard let email = session.email, let first = email.first(where: { $0.isLetter || $0.isNumber }) else {
            return "?"
        }
        return String(first).uppercased()
    }

    // MARK: Intents

    public func avatarTapped() { onIntent(.openSettings) }

    /// Opens the tag's items as a filtered list.
    public func tagTapped(_ tag: TagCount) {
        let forward = onIntent
        openedTag = withDependencies(from: self) {
            TagItemsViewModel(tag: tag.name) { forward($0) }
        }
    }

    // MARK: Rename

    public func renameTapped(_ tag: String) {
        renamingTag = tag
        renameText = tag
        isRenameInvalid = false
        isRenaming = true
    }

    public func cancelRenameTapped() {
        isRenaming = false
        renamingTag = nil
    }

    /// Saves the new name; an empty or too long name keeps the sheet open with the error.
    public func confirmRenameTapped() async {
        guard let from = renamingTag else { return }
        let name = normalizeTagName(renameText)
        guard !name.isEmpty, name.count <= Limits.maxTagLength else {
            isRenameInvalid = true
            return
        }
        switch await tagRepository.rename(from: from, to: name) {
        case .done:
            isRenaming = false
            renamingTag = nil
        case .invalidName:
            isRenameInvalid = true
        }
    }

    // MARK: Delete

    public func deleteTapped(_ tag: String) {
        tagPendingDeletion = tag
        isConfirmingDelete = true
    }

    public func cancelDeleteTapped() {
        isConfirmingDelete = false
        tagPendingDeletion = nil
    }

    /// Removes the tag from every item (the articles stay).
    public func confirmDeleteTapped(_ tag: String) async {
        isConfirmingDelete = false
        tagPendingDeletion = nil
        await tagRepository.delete(name: tag)
        warningFeedbackCount += 1
    }
}
