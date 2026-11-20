import Dependencies
import SnapshotTesting
import SrokaCore
import SrokaDesign
import SrokaTesting
import SwiftUI
import Testing

@testable import TagsFeature

/// Tags tab, one tag's articles, rename sheet and the tag editor on the iPhone 18 Pro. References
/// live in `__Snapshots__/TagsSnapshotTests`; valid only on the iPhone 18 Pro / iOS 27.2 simulator.
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct TagsSnapshotTests {
    init() {
        _ = SrokaFont.registerFonts()
    }

    private func check(
        _ view: some View,
        style: UIUserInterfaceStyle = .light,
        category: UIContentSizeCategory? = nil,
        name: String,
        line: UInt = #line
    ) {
        var traits = [UITraitCollection(userInterfaceStyle: style)]
        if let category { traits.append(UITraitCollection(preferredContentSizeCategory: category)) }
        let controller = UIHostingController(rootView: view.environment(\.usesFlatTagControls, true))
        assertSnapshot(
            of: controller,
            as: .wait(
                for: 1,
                on: .image(
                    on: LibrarySnapshotTests.phone, precision: 0.99, perceptualPrecision: 0.98,
                    traits: UITraitCollection(traitsFrom: traits))),
            named: nil,
            testName: name,
            line: line
        )
    }

    private func tagsScreen(_ tags: [TagCount]?) -> some View {
        NavigationStack {
            TagsScreenContent(tags: tags, avatarLetter: "R", actions: TagsActions())
        }
    }

    private func tagItems(_ items: [ItemSummary]?) -> some View {
        NavigationStack {
            TagItemsContent(
                tag: "birds", items: items, swipeLeftAction: .archive, swipeRightAction: .favorite,
                actions: TagItemsActions())
        }
    }

    /// The editor of the long read (tags essays, web), loaded from the fakes, as sheet content.
    private func editor(draft: String = "") async -> some View {
        let fakes = Fakes()
        let model = withDependencies {
            $0.useFakes(fakes)
        } operation: {
            TagEditorViewModel(itemId: Fixtures.longRead.id)
        }
        model.start()
        for _ in 0..<1000 where !model.isLoaded || model.suggestionChips.isEmpty { await Task.yield() }
        model.draft = draft
        return TagEditorSheet(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(uiColor: .systemBackground))
    }

    // MARK: Tags list

    @Test func tagsLight() {
        check(tagsScreen(Fixtures.tags), name: "tags-light")
    }

    @Test func tagsDark() {
        check(tagsScreen(Fixtures.tags), style: .dark, name: "tags-dark")
    }

    @Test func tagsLargeDynamicType() {
        check(tagsScreen(Fixtures.tags), category: .accessibilityLarge, name: "tags-ax-large")
    }

    @Test func tagsEmpty() {
        check(tagsScreen([]), name: "tags-empty")
    }

    // MARK: One tag's articles

    @Test func tagItemsLight() {
        let items = Fixtures.items.filter { $0.tags.contains("birds") }.map(\.summary)
        check(tagItems(items), name: "tag-items-light")
    }

    // MARK: Rename

    @Test func renameInvalid() {
        check(
            TagRenameSheet(text: .constant("   "), isInvalid: true, onCancel: {}, onSave: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(uiColor: .systemBackground)),
            name: "rename-invalid")
    }

    // MARK: Tag editor

    @Test func editorLight() async {
        check(await editor(), name: "editor-light")
    }

    @Test func editorDark() async {
        check(await editor(), style: .dark, name: "editor-dark")
    }

    @Test func editorLargeDynamicType() async {
        check(await editor(), category: .accessibilityLarge, name: "editor-ax-large")
    }

    @Test func editorTypingNewName() async {
        check(await editor(draft: "sc"), name: "editor-typing")
    }
}
