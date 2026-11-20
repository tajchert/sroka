/// What the Search tab asks the app root for. The search tab never imports the reader.
public enum SearchIntent: Sendable, Hashable {
    /// Open this article in the reader.
    case openItem(id: String)
}
