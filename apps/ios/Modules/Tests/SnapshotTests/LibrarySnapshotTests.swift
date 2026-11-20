import SnapshotTesting
import SrokaCore
import SrokaDesign
import SrokaTesting
import SwiftUI
import Testing

@testable import LibraryFeature

/// Library screens on the iPhone 18 Pro (402 x 874 pt) and an iPad-width window. References live in
/// `__Snapshots__/LibrarySnapshotTests`; valid only on the iPhone 18 Pro / iOS 27.2 simulator.
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct LibrarySnapshotTests {
    static let phone = ViewImageConfig(
        safeArea: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0),
        size: CGSize(width: 402, height: 874),
        traits: UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceIdiom: .phone),
            UITraitCollection(horizontalSizeClass: .compact),
            UITraitCollection(verticalSizeClass: .regular),
            UITraitCollection(displayScale: 3),
        ])
    )

    static let pad = ViewImageConfig(
        safeArea: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0),
        size: CGSize(width: 744, height: 1133),
        traits: UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceIdiom: .pad),
            UITraitCollection(horizontalSizeClass: .regular),
            UITraitCollection(verticalSizeClass: .regular),
            UITraitCollection(displayScale: 2),
        ])
    )

    init() {
        _ = SrokaFont.registerFonts()
    }

    private func screen(_ state: LibraryListState, clipboardHasLink: Bool = false) -> some View {
        NavigationStack {
            LibraryScreenContent(state: state, actions: .none, clipboardHasLink: clipboardHasLink)
        }
    }

    /// Glass buttons and `PasteButton` render blank through `layer.render` and the test bundle has no
    /// host app for `drawHierarchy`, so the screens swap them for flat stand-ins (`usesFlatControls`).
    private func check(
        _ view: some View,
        on config: ViewImageConfig = phone,
        style: UIUserInterfaceStyle = .light,
        category: UIContentSizeCategory? = nil,
        name: String,
        line: UInt = #line
    ) {
        var traits = [UITraitCollection(userInterfaceStyle: style)]
        if let category { traits.append(UITraitCollection(preferredContentSizeCategory: category)) }
        let controller = UIHostingController(rootView: view.environment(\.usesFlatControls, true))
        assertSnapshot(
            of: controller,
            as: .wait(
                for: 1,
                on: .image(
                    on: config, precision: 0.99, perceptualPrecision: 0.98,
                    traits: UITraitCollection(traitsFrom: traits))),
            named: nil,
            testName: name,
            line: line
        )
    }

    @Test func myListLight() {
        check(screen(.previewMyList), name: "my-list-light")
    }

    @Test func myListDark() {
        check(screen(.previewMyList), style: .dark, name: "my-list-dark")
    }

    @Test func myListLargeDynamicType() {
        check(screen(.previewMyList), category: .accessibilityLarge, name: "my-list-ax-large")
    }

    @Test func myListWithClipboardChipAndFilters() {
        var state = LibraryListState.previewMyList
        state.statusCard = .downloading(done: 2, total: 5)
        state.filters = ListFilters(favoritesOnly: true)
        check(screen(state, clipboardHasLink: true), name: "my-list-filters-downloading")
    }

    @Test func archive() {
        var state = LibraryListState()
        state.scope = .archive
        state.items = Fixtures.items.filter { $0.status == .archived }.map(\.summary)
        state.avatarLetter = "R"
        state.isLoaded = true
        check(screen(state), name: "archive")
    }

    @Test func onboarding() {
        var state = LibraryListState()
        state.isLoaded = true
        state.emptyState = .onboarding
        state.avatarLetter = "R"
        state.extensionConnected = true
        check(screen(state), name: "onboarding")
    }

    @Test func noMatches() {
        var state = LibraryListState()
        state.isLoaded = true
        state.emptyState = .noMatches
        state.avatarLetter = "R"
        state.filters = ListFilters(favoritesOnly: true)
        check(screen(state), name: "no-matches")
    }

    @Test func addSheet() {
        let sheet = AddLinkSheet(
            text: .constant("https://example.com/story"),
            isInvalid: false,
            onCancel: {},
            onSave: {},
            onPaste: { _ in },
            onChoosePdf: {}
        )
        check(sheet, name: "add-sheet")
    }

    @Test func iPadWidth() {
        check(screen(.previewMyList), on: Self.pad, name: "my-list-ipad")
    }
}
