import Testing

@testable import SearchFeature

@MainActor
struct SearchFeatureTests {
    @Test func `Placeholder view builds`() {
        _ = SearchPlaceholderView().body
    }
}
