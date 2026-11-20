import Foundation
import SrokaCore

/// Text produced by view models (toasts, validation), the same words as Android. View text uses
/// `Text("…", bundle: #bundle)` directly.
enum TagsStrings {
    static let undo = LocalizedStringResource("Undo", bundle: #bundle)

    static func archived(offline: Bool) -> LocalizedStringResource {
        offline
            ? LocalizedStringResource("Archived. Syncs when you’re online.", bundle: #bundle)
            : LocalizedStringResource("Archived", bundle: #bundle)
    }

    static func unarchived(offline: Bool) -> LocalizedStringResource {
        offline
            ? LocalizedStringResource("Moved to My List. Syncs when you’re online.", bundle: #bundle)
            : LocalizedStringResource("Moved to My List", bundle: #bundle)
    }

    static let addedToFavorites = LocalizedStringResource("Added to favorites", bundle: #bundle)
    static let removedFromFavorites = LocalizedStringResource("Removed from favorites", bundle: #bundle)
    static let articleDeleted = LocalizedStringResource("Article deleted", bundle: #bundle)
    static let refreshing = LocalizedStringResource("Refreshing article", bundle: #bundle)
}
