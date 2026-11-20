import Dependencies
import SnapshotTesting
import SrokaCore
import SrokaDesign
import SrokaTesting
import SwiftUI
import Testing

@testable import ReaderFeature

/// Reader screens that need no web view: status pages, appearance sheet, end-of-article card and chrome.
@MainActor
@Suite(.snapshots(record: .missing))
struct ReaderSnapshotTests {
    private let url = URL(string: "https://example.com/story")

    private func page<Content: View>(
        _ theme: EffectiveTheme = .light, height: CGFloat = 420, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(width: 402, height: height)
            .background(theme.palette.background)
    }

    private func check(
        _ view: some View, height: CGFloat = 420, testName: String = #function, line: UInt = #line
    ) {
        assertSnapshot(
            of: view, as: .image(layout: .fixed(width: 402, height: height)), testName: testName, line: line)
    }

    // MARK: Status pages

    @Test func readerDownloading() {
        check(page { ReaderDownloadingView(isPdf: false, theme: .light) })
    }

    @Test func readerDownloadingPdfDark() {
        check(page(.dark) { ReaderDownloadingView(isPdf: true, theme: .dark) })
    }

    @Test func readerNotDownloadedOffline() {
        check(
            page {
                ReaderNotDownloadedView(reason: .offline, isPdf: false, originalURL: url, theme: .light, onRetry: {})
            })
    }

    @Test func readerNotDownloadedSignInSepia() {
        check(
            page(.sepia) {
                ReaderNotDownloadedView(reason: .signIn, isPdf: false, originalURL: url, theme: .sepia, onRetry: {})
            })
    }

    @Test func readerParsePending() {
        check(page { ReaderParsePendingView(originalURL: url, theme: .light) })
    }

    @Test func readerParseFailed() {
        check(
            page {
                ReaderParseFailedView(error: "paywalled", originalURL: url, theme: .light, onTryAgain: {})
            })
    }

    @Test func readerParseFailedDark() {
        check(
            page(.dark) {
                ReaderParseFailedView(error: nil, originalURL: url, theme: .dark, onTryAgain: {})
            })
    }

    @Test func readerRendererGone() {
        check(page { ReaderRendererGoneView(originalURL: url, theme: .light, onReload: {}) })
    }

    // MARK: End of article

    // The glass surface of the card and its prominent button render blank off-screen, so the parts are
    // snapshotted on their own; the glass itself is judged on a device.
    @Test func endCardHeaderAndUpNext() {
        check(
            page(.light, height: 200) {
                VStack(alignment: .leading, spacing: 16) {
                    EndCardHeader(minutes: 6)
                    EndCardUpNext(item: Fixtures.longRead.summary, onOpen: {})
                }
                .padding(18)
            }, height: 200)
    }

    @Test func endCardHeaderWithoutMinutes() {
        check(page(.light, height: 80) { EndCardHeader(minutes: nil).padding(18) }, height: 80)
    }

    // MARK: Appearance sheet

    private func appearanceModel(_ preferences: UserPreferences) async -> (ReaderAppearanceModel, Task<Void, Never>) {
        let fakes = Fakes(preferences: preferences)
        let model = withDependencies {
            $0.useFakes(fakes)
        } operation: {
            ReaderAppearanceModel()
        }
        let task = Task { await model.observe() }
        for _ in 0..<500 where !model.isLoaded { await Task.yield() }
        return (model, task)
    }

    @Test func appearanceSheetLight() async {
        let (model, task) = await appearanceModel(UserPreferences())
        defer { task.cancel() }
        check(AppearanceSheet(model: model).frame(width: 402).background(Color(.systemBackground)), height: 430)
    }

    @Test func appearanceSheetSerifSepiaLarge() async {
        let preferences = UserPreferences(
            readerTheme: .sepia, readerTextScale: 1.4, readerFont: .serif, readerLineSpacing: .loose)
        let (model, task) = await appearanceModel(preferences)
        defer { task.cancel() }
        check(AppearanceSheet(model: model).frame(width: 402).background(Color(.systemBackground)), height: 430)
    }

    // MARK: Chrome

    @Test func toastsAndProgressLine() {
        let view = VStack(spacing: 16) {
            ReaderToastContent(theme: .light, toast: .resumed(percent: 42), onStartOver: {})
            ReaderToastContent(theme: .light, toast: .refreshedPartial, onStartOver: {})
            ReaderProgressLine(progress: 0.42, theme: .light)
        }
        .padding()
        .frame(width: 402, height: 200)
        .background(EffectiveTheme.light.palette.background)
        check(view, height: 200)
    }

    // MARK: PDF

    @Test func pdfUnreadable() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "unreadable-\(UUID().uuidString).pdf")
        try Data("not a pdf".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        check(page { PdfUnreadableView(file: file, theme: .light) })
    }
}
