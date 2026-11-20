import Foundation

/// What the Tags tab, a tag's item list and the tag editor ask the app root to do. TagsFeature
/// never imports the features that own these destinations; the root handles each intent.
public enum TagsIntent: Sendable, Hashable {
    /// Push the tag's item list (`TagItemsView`, built with `TagsViewModel.itemsModel(for:)`) on the Tags
    /// stack. The root owns the stack so a reader opened from the list lands on top of it.
    case openTag(name: String)
    /// The open item list's tag no longer exists (renamed or deleted); the root drops that screen.
    case closeTag(name: String)
    /// Open the article or PDF in the reader.
    case openItem(id: String)
    /// Present the tag editor for the item (`TagEditorSheet` of this module).
    case editTags(id: String)
    /// Open Settings (avatar button).
    case openSettings
    /// Open a web address (original article) in the system browser.
    case openURL(URL)
}
