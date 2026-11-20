import Dependencies
import SrokaCore
import SrokaDesign
import SrokaTesting
import SwiftUI

#Preview("Tags") {
    let _ = SrokaFont.registerFonts()
    NavigationStack {
        TagsScreenContent(tags: Fixtures.tags, avatarLetter: "R", actions: TagsActions())
    }
}

#Preview("No tags") {
    let _ = SrokaFont.registerFonts()
    NavigationStack {
        TagsScreenContent(tags: [], avatarLetter: "R", actions: TagsActions())
    }
}

#Preview("Tag items") {
    let _ = SrokaFont.registerFonts()
    NavigationStack {
        TagItemsContent(
            tag: "swift",
            items: Fixtures.items.map(\.summary),
            swipeLeftAction: .archive,
            swipeRightAction: .favorite,
            actions: TagItemsActions()
        )
    }
}

#Preview("Rename") {
    TagRenameSheet(text: .constant("swift"), isInvalid: true, onCancel: {}, onSave: {})
}

#Preview("Tag editor with fakes") {
    let fakes = Fakes()
    let model = withDependencies {
        $0.useFakes(fakes)
    } operation: {
        TagEditorViewModel(itemId: Fixtures.longRead.id) {}
    }
    Color.clear.sheet(isPresented: .constant(true)) { TagEditorSheet(model: model) }
}

#Preview("Live with fakes") {
    let fakes = Fakes()
    let model = withDependencies {
        $0.useFakes(fakes)
    } operation: {
        TagsViewModel()
    }
    NavigationStack { TagsView(model: model) }
}
