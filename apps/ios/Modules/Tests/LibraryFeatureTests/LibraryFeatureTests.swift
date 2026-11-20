import Testing

@testable import LibraryFeature

@MainActor
struct LibraryFeatureTests {
    @Test func `Placeholder view builds`() {
        _ = LibraryPlaceholderView().body
    }
}
