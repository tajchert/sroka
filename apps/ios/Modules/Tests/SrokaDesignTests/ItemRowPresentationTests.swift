import Foundation
import SrokaCore
import Testing

@testable import SrokaDesign

struct ItemRowPresentationTests {
    private func item(
        minutes: Int? = 8,
        progress: Double = 0,
        parse: ParseStatus = .ok,
        parseError: String? = nil,
        offline: OfflineState = .downloaded,
        pending: PendingChange? = nil,
        kind: ItemKind = .article,
        fileSize: Int64? = nil
    ) -> ItemSummary {
        ItemSummary(
            id: "i1",
            displayTitle: "Title",
            domain: "example.com",
            readingMinutes: minutes,
            progress: progress,
            parseStatus: parse,
            offline: offline,
            savedAt: Date(timeIntervalSince1970: 0),
            pendingChange: pending,
            kind: kind,
            fileSize: fileSize,
            parseError: parseError
        )
    }

    @Test func `A plain downloaded article has no status`() {
        let presentation = ItemRowPresentation(item())
        #expect(presentation.status == nil)
        #expect(presentation.metaText == "example.com · 8 min")
        #expect(presentation.readState == .unread)
    }

    @Test func `A pending change outranks every other status`() {
        let presentation = ItemRowPresentation(item(parse: .failed, offline: .availableRemote, pending: .favorite))
        #expect(presentation.status == .waitingToSync)
        #expect(presentation.metaText.hasSuffix("Waiting to sync"))
    }

    @Test func `Parse state maps to failed, preview only, partial copy and preparing`() {
        #expect(ItemRowPresentation(item(parse: .failed)).status == .failed)
        #expect(ItemRowPresentation(item(parse: .failed)).showsRetry)
        #expect(ItemRowPresentation(item(parse: .partial, parseError: "paywalled")).status == .previewOnly)
        #expect(ItemRowPresentation(item(parse: .partial)).status == .partialCopy)
        #expect(ItemRowPresentation(item(parse: .pending)).status == .preparing)
    }

    @Test func `Offline state maps to downloading and not on this device`() {
        #expect(ItemRowPresentation(item(offline: .downloading)).status == .downloading)
        #expect(ItemRowPresentation(item(offline: .queued)).status == .downloading)
        #expect(ItemRowPresentation(item(offline: .availableRemote)).status == .notOnDevice)
        #expect(ItemRowPresentation(item(offline: .failed)).status == nil)
    }

    @Test func `Badge-only statuses stay out of the meta line`() {
        #expect(ItemRowPresentation(item(offline: .availableRemote)).metaText == "example.com · 8 min")
    }

    @Test func `Progress sets the read state and the time left`() {
        let partway = ItemRowPresentation(item(minutes: 10, progress: 0.4))
        #expect(partway.readState == .inProgress)
        #expect(partway.showsProgressBar)
        #expect(partway.metaText == "example.com · 6 min left")
        let done = ItemRowPresentation(item(progress: 0.98))
        #expect(done.readState == .read)
        #expect(done.metaText == "example.com · ✓ Read")
        #expect(ItemRowPresentation(item(progress: 0.01)).readState == .unread)
    }

    @Test func `Minutes left is at least one and rounds up`() {
        #expect(ItemRowPresentation.minutesLeft(10, progress: 0.97) == 1)
        #expect(ItemRowPresentation.minutesLeft(9, progress: 0.5) == 5)
        #expect(ItemRowPresentation.minutesLeft(10, progress: 0.5) == 5)
    }

    @Test func `PDF rows show the file size in decimal units`() {
        let megabytes = ItemRowPresentation(item(kind: .pdf, fileSize: 2_300_000)).metaText
        #expect(megabytes.hasPrefix("PDF · 2") && megabytes.hasSuffix("3 MB"))  // decimal separator follows the locale
        #expect(ItemRowPresentation(item(kind: .pdf, fileSize: 820_400)).metaText == "PDF · 820 KB")
        #expect(ItemRowPresentation(item(kind: .pdf, fileSize: 90)).metaText == "PDF · 90 B")
        #expect(ItemRowPresentation(item(kind: .pdf)).metaText == "PDF")
        #expect(ItemRowPresentation(item(kind: .pdf)).isPDF)
    }

    @Test func `The accessibility label joins title, details and badge-only status`() {
        let label = ItemRowPresentation(item(minutes: 10, progress: 0.4, offline: .availableRemote))
            .accessibilityLabel(title: "Title")
        #expect(label == "Title, example.com · 6 min left, 40% read, Not on this device")
    }
}
