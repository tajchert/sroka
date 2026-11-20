import AuthFeature
import LibraryFeature
import ReaderFeature
import SearchFeature
import SettingsFeature
import ShareFeature
import SnapshotTesting
import SrokaDesign
import SrokaTesting
import SwiftUI
import TagsFeature
import Testing

/// Screen and component snapshots live here (iPhone 18 Pro / iOS 27.2 only). Feature streams add
/// suites with `@Suite(.snapshots(record: .missing))` and `assertSnapshot(of:as:)`; references go to
/// `__Snapshots__/`. This placeholder only proves every feature module links into the target.
@MainActor
struct SnapshotTargetTests {
    @Test func `Feature modules link`() {
        _ = LibraryView.self
        _ = TagsView.self
        _ = SearchView.self
        _ = ReaderView.self
        _ = SharePlaceholderView()
        _ = Fixtures.items
    }
}
