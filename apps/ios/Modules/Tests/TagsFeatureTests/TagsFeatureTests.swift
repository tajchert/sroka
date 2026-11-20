import Clocks
import Dependencies
import Foundation
import SrokaCore
import SrokaTesting
import Testing

@testable import TagsFeature

/// Shared setup of the Tags suites: fakes, a `TestClock` and a log of the intents the app root
/// would handle.
@MainActor
final class TagsTestBed {
    let fakes: Fakes
    let clock = TestClock<Duration>()
    var intents: [TagsIntent] = []

    init(items: [Item] = Fixtures.items) {
        fakes = Fakes(items: items, preferences: UserPreferences(swipeHintShown: true))
    }

    func make<Model>(_ build: () -> Model) -> Model {
        let fakes = fakes
        let clock = clock
        return withDependencies {
            $0.useFakes(fakes)
            $0.continuousClock = clock
        } operation: {
            build()
        }
    }

    /// Lets the observation tasks run until `condition` holds (no sleeping).
    func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }
}

@MainActor
struct TagsViewModelTests {
    let bed = TagsTestBed()

    func makeModel() async -> TagsViewModel {
        let bed = bed
        let model = bed.make { TagsViewModel { bed.intents.append($0) } }
        model.start()
        await bed.until { model.tags != nil }
        return model
    }

    @Test func `The tag list shows each tag with its article count`() async {
        let model = await makeModel()
        #expect(model.tags?.map(\.name) == Fixtures.tags.map(\.name))
        #expect(model.tags?.first { $0.name == "birds" }?.count == 2)
    }

    @Test func `The avatar shows the first letter of the account email`() async {
        let model = await makeModel()
        await bed.until { model.avatarLetter != "?" }
        #expect(model.avatarLetter == "R")
        model.avatarTapped()
        #expect(bed.intents == [.openSettings])
    }

    @Test func `Opening a tag lists its articles from My List and Archive`() async throws {
        let model = await makeModel()
        model.tagTapped(TagCount(name: "birds", count: 2))
        let opened = try #require(model.openedTag)
        opened.start()
        await bed.until { opened.isLoaded }
        #expect(opened.tag == "birds")
        #expect(Set(opened.items.map(\.id)) == ["a2-short-news", "a7-archived-fav"])
    }

    @Test func `Renaming a tag changes it on every article`() async {
        let model = await makeModel()
        model.renameTapped("birds")
        #expect(model.isRenaming)
        #expect(model.renameText == "birds")
        model.renameText = "  corvids  "
        await model.confirmRenameTapped()
        #expect(!model.isRenaming)
        #expect(bed.fakes.library.item(id: "a2-short-news")?.tags.contains("corvids") == true)
        await bed.until { model.tags?.contains { $0.name == "corvids" } == true }
        #expect(model.tags?.contains { $0.name == "birds" } == false)
    }

    @Test func `An empty or too long name keeps the rename sheet open with the error`() async {
        let model = await makeModel()
        model.renameTapped("birds")
        model.renameText = "   "
        await model.confirmRenameTapped()
        #expect(model.isRenaming)
        #expect(model.isRenameInvalid)
        model.renameText = String(repeating: "a", count: Limits.maxTagLength + 1)
        #expect(!model.isRenameInvalid)
        await model.confirmRenameTapped()
        #expect(model.isRenameInvalid)
        #expect(bed.fakes.library.item(id: "a2-short-news")?.tags.contains("birds") == true)
    }

    @Test func `Cancelling the rename leaves the tag as it is`() async {
        let model = await makeModel()
        model.renameTapped("birds")
        model.cancelRenameTapped()
        #expect(!model.isRenaming)
        #expect(model.renamingTag == nil)
    }

    @Test func `Deleting a tag asks first, then removes it from every article`() async {
        let model = await makeModel()
        model.deleteTapped("birds")
        #expect(model.isConfirmingDelete)
        #expect(model.tagPendingDeletion == "birds")
        #expect(bed.fakes.library.item(id: "a2-short-news")?.tags.contains("birds") == true)
        await model.confirmDeleteTapped("birds")
        #expect(!model.isConfirmingDelete)
        #expect(model.warningFeedbackCount == 1)
        #expect(bed.fakes.library.item(id: "a2-short-news")?.tags == ["science"])
        // The articles stay.
        #expect(bed.fakes.library.item(id: "a7-archived-fav") != nil)
        await bed.until { model.tags?.contains { $0.name == "birds" } == false }
        #expect(model.tags?.contains { $0.name == "birds" } == false)
    }

    @Test func `Cancelling the delete keeps the tag`() async {
        let model = await makeModel()
        model.deleteTapped("birds")
        model.cancelDeleteTapped()
        #expect(!model.isConfirmingDelete)
        #expect(model.tagPendingDeletion == nil)
        #expect(bed.fakes.library.item(id: "a2-short-news")?.tags.contains("birds") == true)
    }

    @Test func `With no tags the list is empty, not loading`() async {
        let bed = TagsTestBed(items: [])
        let model = bed.make { TagsViewModel() }
        model.start()
        await bed.until { model.tags != nil }
        #expect(model.tags?.isEmpty == true)
    }
}

@MainActor
struct TagItemsViewModelTests {
    let bed = TagsTestBed()

    func makeModel(tag: String = "birds") async -> TagItemsViewModel {
        let bed = bed
        let model = bed.make { TagItemsViewModel(tag: tag) { bed.intents.append($0) } }
        model.start()
        await bed.until { model.isLoaded }
        return model
    }

    func text(_ resource: LocalizedStringResource?) -> String? {
        resource.map { String(localized: $0) }
    }

    @Test func `Tapping a row opens the article and edit tags asks for the editor`() async {
        let model = await makeModel()
        let item = model.items[0]
        model.itemTapped(item)
        model.editTagsTapped(item)
        #expect(bed.intents == [.openItem(id: item.id), .editTags(id: item.id)])
    }

    @Test func `Swiping uses the configured actions`() async throws {
        let model = await makeModel()
        await bed.until { model.swipeLeftAction == .archive }
        #expect(model.action(for: .trailing) == .archive)
        let item = try #require(model.items.first { $0.status == .unread })
        await model.swiped(.trailing, item: item)
        #expect(bed.fakes.library.item(id: item.id)?.status == .archived)
        #expect(text(model.toast?.message) == "Archived")
    }

    @Test func `Undo puts the article back and the toast goes away after four seconds`() async throws {
        let model = await makeModel()
        let item = try #require(model.items.first { $0.status == .unread })
        await model.archiveTapped(item)
        #expect(model.toast?.undo == .status(id: item.id, previous: .unread))
        await model.undoTapped()
        #expect(bed.fakes.library.item(id: item.id)?.status == .unread)
        #expect(model.toast == nil)

        await model.favoriteTapped(item)
        #expect(model.toast != nil)
        for _ in 0..<20 { await Task.yield() }
        await bed.clock.advance(by: .seconds(4))
        await bed.until { model.toast == nil }
        #expect(model.toast == nil)
    }

    @Test func `Deleting an article asks for confirmation first`() async throws {
        let model = await makeModel()
        let item = try #require(model.items.first)
        model.deleteTapped(item)
        #expect(model.isConfirmingDelete)
        #expect(bed.fakes.library.item(id: item.id) != nil)
        await model.confirmDeleteTapped()
        #expect(bed.fakes.library.item(id: item.id) == nil)
        #expect(model.warningFeedbackCount == 1)
        #expect(text(model.toast?.message) == "Article deleted")
    }

    @Test func `A tag without articles shows an empty list once loaded`() async {
        let model = await makeModel(tag: "nothing-here")
        #expect(model.items.isEmpty)
        #expect(model.isLoaded)
    }

    @Test func `Open original and share ask for the article address`() async throws {
        let model = await makeModel()
        let item = try #require(model.items.first)
        await model.openOriginalTapped(item)
        await model.shareLinkTapped(item)
        let address = try #require(bed.fakes.library.item(id: item.id)?.url)
        let url = try #require(URL(string: address))
        #expect(bed.intents == [.openURL(url)])
        #expect(model.shareRequest?.url == url)
    }
}

@MainActor
struct TagEditorViewModelTests {
    let bed = TagsTestBed()
    let finished = FinishCounter()

    final class FinishCounter {
        var count = 0
    }

    func makeModel(itemId: String = "a1-long-read", items: [Item]? = nil) async -> TagEditorViewModel {
        let bed = items.map { TagsTestBed(items: $0) } ?? bed
        let counter = finished
        let model = bed.make { TagEditorViewModel(itemId: itemId) { counter.count += 1 } }
        model.start()
        await bed.until { model.isLoaded }
        return model
    }

    @Test func `The editor starts with the item's tags`() async {
        let model = await makeModel()
        #expect(model.tags == ["essays", "web"])
        #expect(model.canSave)
    }

    @Test func `Recent tags are suggested except the ones already on the item`() async {
        let model = await makeModel()
        await bed.until { !model.suggestionChips.isEmpty }
        let names = model.suggestionChips.map(\.name)
        #expect(names.contains("birds"))
        #expect(!names.contains("essays"))
        #expect(!names.contains("web"))
        #expect(!model.suggestionChips.contains { if case .create = $0 { true } else { false } })
    }

    @Test func `Typing a new name offers Create and adding it normalises the name`() async {
        let model = await makeModel()
        model.draft = "  deep   dive "
        #expect(model.suggestionChips.first == .create("deep dive"))
        model.addDraftTapped()
        #expect(model.tags == ["essays", "web", "deep dive"])
        #expect(model.draft.isEmpty)
    }

    @Test func `Typing an existing tag offers it instead of Create`() async {
        let model = await makeModel()
        await bed.until { !model.suggestionChips.isEmpty }
        model.draft = "BIRDS"
        #expect(model.suggestionChips == [.existing("birds")])
        model.draft = "BIR"
        #expect(model.suggestionChips == [.create("BIR"), .existing("birds")])
    }

    @Test func `Tapping a suggestion adds it and a duplicate is ignored`() async {
        let model = await makeModel()
        model.suggestionTapped("birds")
        model.suggestionTapped("Birds")
        #expect(model.tags == ["essays", "web", "birds"])
    }

    @Test func `Removing a tag puts it back in the suggestions`() async {
        let model = await makeModel()
        model.removeTapped("web")
        #expect(model.tags == ["essays"])
        await bed.until { model.suggestionChips.contains(.existing("web")) }
        #expect(model.suggestionChips.contains(.existing("web")))
    }

    @Test func `A tag name is cut to 64 characters`() async {
        let model = await makeModel()
        model.draft = String(repeating: "x", count: 80)
        #expect(model.draft.count == Limits.maxTagLength)
        model.addDraftTapped()
        #expect(model.tags.last?.count == Limits.maxTagLength)
    }

    @Test func `An item holds at most 100 tags`() async {
        var item = Fixtures.longRead
        item.tags = (1...Limits.maxTagsPerItem).map { "tag\($0)" }
        let model = await makeModel(items: [item])
        #expect(model.isAtLimit)
        model.draft = "one more"
        #expect(model.suggestionChips.isEmpty)
        model.addDraftTapped()
        #expect(model.tags.count == Limits.maxTagsPerItem)
        #expect(!model.tags.contains("one more"))
    }

    @Test func `Save writes the tags, including text still in the field, then finishes`() async {
        let model = await makeModel()
        model.removeTapped("essays")
        model.draft = "fresh"
        await model.saveTapped()
        #expect(Set(bed.fakes.library.item(id: "a1-long-read")?.tags ?? []) == ["web", "fresh"])
        #expect(finished.count == 1)
    }

    @Test func `Cancel changes nothing and finishes`() async {
        let model = await makeModel()
        model.suggestionTapped("birds")
        await model.cancelTapped()
        #expect(bed.fakes.library.item(id: "a1-long-read")?.tags == ["essays", "web"])
        #expect(finished.count == 1)
    }

    @Test func `A sync that changes the item does not overwrite the edits`() async {
        let model = await makeModel()
        model.suggestionTapped("birds")
        await bed.fakes.library.setTags(id: "a1-long-read", names: ["other"])
        for _ in 0..<50 { await Task.yield() }
        #expect(model.tags == ["essays", "web", "birds"])
    }

    @Test func `An item deleted while editing disables Save`() async {
        let model = await makeModel(itemId: "missing")
        #expect(model.itemIsGone)
        #expect(!model.canSave)
    }
}
