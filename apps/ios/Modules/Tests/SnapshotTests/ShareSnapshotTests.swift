import SnapshotTesting
import SrokaCore
import SrokaDesign
import SrokaTesting
import SwiftUI
import Testing

@testable import ShareFeature

/// Every state of the share extension's save sheet, light and dark, at the sheet's own size (402 x 340 pt:
/// the width of the iPhone 18 Pro and the small detent). References live in `__Snapshots__/ShareSnapshotTests`;
/// valid only on the iPhone 18 Pro / iOS 27.2 simulator.
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct ShareSnapshotTests {
    static let sheet = ViewImageConfig(
        safeArea: .zero,
        size: CGSize(width: 402, height: 340),
        traits: UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceIdiom: .phone),
            UITraitCollection(horizontalSizeClass: .compact),
            UITraitCollection(verticalSizeClass: .regular),
            UITraitCollection(displayScale: 3),
        ])
    )

    init() {
        _ = SrokaFont.registerFonts()
    }

    private func check(_ state: ShareSheetState, dark: Bool = false, name: String, line: UInt = #line) {
        let view = ShareSheetContent(state: state, actions: .none)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(SrokaColor.background.ignoresSafeArea())
            .environment(\.usesFlatControls, true)
        let controller = UIHostingController(rootView: view)
        assertSnapshot(
            of: controller,
            as: .wait(
                for: 1,
                on: .image(
                    on: Self.sheet, precision: 0.99, perceptualPrecision: 0.98,
                    traits: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))),
            named: nil,
            testName: name,
            line: line
        )
    }

    @Test func savedLight() { check(.previewJustSaved, name: "saved-light") }
    @Test func savedDark() { check(.previewJustSaved, dark: true, name: "saved-dark") }
    @Test func favoritedLight() { check(.previewFavorited, name: "favorited-light") }
    @Test func favoritedDark() { check(.previewFavorited, dark: true, name: "favorited-dark") }
    @Test func alreadySavedLight() { check(.previewAlreadySaved, name: "already-saved-light") }
    @Test func alreadySavedDark() { check(.previewAlreadySaved, dark: true, name: "already-saved-dark") }
    @Test func noLinkLight() { check(.previewNoLink, name: "no-link-light") }
    @Test func noLinkDark() { check(.previewNoLink, dark: true, name: "no-link-dark") }
    @Test func signedOutLight() { check(.previewSignedOut, name: "signed-out-light") }
    @Test func signedOutDark() { check(.previewSignedOut, dark: true, name: "signed-out-dark") }
    @Test func needsAppLight() { check(.previewNeedsApp, name: "needs-app-light") }
    @Test func needsAppDark() { check(.previewNeedsApp, dark: true, name: "needs-app-dark") }
    @Test func errorLight() { check(.previewError, name: "error-light") }
    @Test func errorDark() { check(.previewError, dark: true, name: "error-dark") }
    @Test func pdfQueuedLight() { check(.previewPdfQueued, name: "pdf-queued-light") }
    @Test func pdfQueuedDark() { check(.previewPdfQueued, dark: true, name: "pdf-queued-dark") }
    @Test func pdfAddedLight() { check(.previewPdfAdded, name: "pdf-added-light") }
    @Test func pdfFailedLight() { check(.previewPdfFailed, name: "pdf-failed-light") }
}
