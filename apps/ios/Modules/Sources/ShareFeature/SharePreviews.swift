import SrokaCore
import SrokaDesign
import SrokaTesting
import SwiftUI

extension ShareSheetState {
    /// The mock-up's article: saved a moment ago, already parsed.
    static let previewItem = Item(
        id: "share-preview",
        url: "https://en.wikipedia.org/wiki/Eurasian_magpie",
        title: "Eurasian magpie",
        readingMinutes: 9,
        contentId: "c-share",
        parseStatus: .ok,
        savedAt: Fixtures.now,
        source: .share,
        offline: .downloaded
    )

    static let previewJustSaved = ShareSheetState(
        phase: .saved(itemId: previewItem.id, alreadySaved: false),
        item: previewItem,
        countdown: .frozen(0.6)
    )

    static var previewFavorited: ShareSheetState {
        var state = previewJustSaved
        state.item?.isFavorite = true
        return state
    }

    static var previewAlreadySaved: ShareSheetState {
        ShareSheetState(
            phase: .saved(itemId: Fixtures.longRead.id, alreadySaved: true),
            item: Fixtures.longRead,
            countdown: .frozen(0.6)
        )
    }

    static let previewNoLink = ShareSheetState(phase: .noLink, countdown: .frozen(0.6))
    static let previewSignedOut = ShareSheetState(phase: .needsSignIn)
    static let previewNeedsApp = ShareSheetState(phase: .needsApp)
    static let previewError = ShareSheetState(phase: .error)
    static let previewPdfQueued = ShareSheetState(phase: .pdf(.queued(count: 1)), countdown: .frozen(0.6))
    static let previewPdfAdded = ShareSheetState(phase: .pdf(.added(count: 1)), countdown: .frozen(0.6))
    static let previewPdfFailed = ShareSheetState(phase: .pdf(.failed(.tooLarge)))
}

#Preview("Saved") {
    ShareSheetContent(state: .previewJustSaved, actions: .none)
        .background(SrokaColor.background)
}

#Preview("Already saved") {
    ShareSheetContent(state: .previewAlreadySaved, actions: .none)
        .background(SrokaColor.background)
}

#Preview("Signed out") {
    ShareSheetContent(state: .previewSignedOut, actions: .none)
        .background(SrokaColor.background)
}

#Preview("PDF") {
    ShareSheetContent(state: .previewPdfQueued, actions: .none)
        .background(SrokaColor.background)
}
