import Dependencies
import SrokaCore
import SrokaDesign
import SrokaTesting
import SwiftUI

extension LibraryListState {
    /// My List with every row variant, chips, a continue-reading strip and the offline card.
    static var previewMyList: LibraryListState {
        LibraryListState(
            items: Fixtures.items.filter { $0.status == .unread }.map(\.summary),
            continueReading: [Fixtures.longRead.summary],
            tagChips: Fixtures.tags.prefix(5).map(\.name),
            statusCard: .offline(pendingChanges: 2),
            avatarLetter: "R"
        )
    }
}

#Preview("My List") {
    let _ = SrokaFont.registerFonts()
    NavigationStack {
        LibraryScreenContent(state: .previewMyList, actions: .none)
    }
}

#Preview("Onboarding") {
    let _ = SrokaFont.registerFonts()
    NavigationStack {
        LibraryScreenContent(
            state: LibraryListState(emptyState: .onboarding, avatarLetter: "R", extensionConnected: true),
            actions: .none
        )
    }
}

#Preview("Add link") {
    AddLinkSheet(
        text: .constant("https://example.com/story"),
        isInvalid: false,
        onCancel: {},
        onSave: {},
        onPaste: { _ in },
        onChoosePdf: {}
    )
}

#Preview("Live with fakes") {
    let fakes = Fakes()
    let model = withDependencies {
        $0.useFakes(fakes)
    } operation: {
        LibraryViewModel()
    }
    NavigationStack { LibraryView(model: model) }
}
