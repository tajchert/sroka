import Testing

@testable import TagsFeature

@MainActor
struct TagsFeatureTests {
    @Test func `Placeholder view builds`() {
        _ = TagsPlaceholderView().body
    }
}
