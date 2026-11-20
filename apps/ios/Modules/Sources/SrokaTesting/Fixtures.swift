import Foundation
import SrokaCore

/// Deterministic sample data for previews, tests and snapshots. Dates are relative to `now`, a fixed
/// instant, so rendered "2 h ago" labels never drift.
public enum Fixtures {
    /// 2026-11-03 09:30:00 UTC.
    public static let now = Date(timeIntervalSince1970: 1_793_784_600)
    public static let email = "reader@example.com"

    static func ago(hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    // MARK: Items

    /// Long-form article, partly read, downloaded, tagged.
    public static let longRead = Item(
        id: "a1-long-read",
        url: "https://www.example.com/essays/the-slow-web",
        title: "The slow web: why reading later still matters",
        excerpt: "A decade after the read-later boom, the habit of saving things for a quiet moment is back.",
        siteName: "Example Essays",
        author: "Ada Writer",
        lang: "en",
        wordCount: 4200,
        readingMinutes: 17,
        contentId: "c1",
        parseStatus: .ok,
        progress: 0.42,
        progressAnchor: 31,
        savedAt: ago(hours: 2),
        lastReadAt: ago(hours: 1),
        source: .extensionSource,
        tags: ["essays", "web"],
        offline: .downloaded
    )

    /// Short news piece, unread, favourite.
    public static let shortNews = Item(
        id: "a2-short-news",
        url: "https://news.example.org/2026/11/magpies-recognise-faces",
        title: "Magpies recognise human faces, study finds",
        excerpt: "Researchers found that magpies remember people who disturbed their nests for years.",
        siteName: "Example News",
        wordCount: 600,
        readingMinutes: 3,
        contentId: "c2",
        parseStatus: .ok,
        isFavorite: true,
        savedAt: ago(hours: 5),
        source: .share,
        tags: ["birds", "science"],
        offline: .downloaded
    )

    /// Saved a moment ago, still parsing; no title yet (falls back to the domain).
    public static let pendingParse = Item(
        id: "a3-pending",
        url: "https://blog.example.net/posts/compose-vs-swiftui",
        parseStatus: .pending,
        savedAt: ago(hours: 0.01),
        source: .share,
        pendingChange: .save
    )

    /// Parse failed (paywall); offers "open original".
    public static let paywalled = Item(
        id: "a4-paywalled",
        url: "https://paper.example.com/premium/market-outlook",
        title: "Market outlook for 2027",
        siteName: "Example Paper",
        parseStatus: .failed,
        parseError: "paywall",
        savedAt: ago(hours: 26),
        source: .web,
        tags: ["finance"],
        offline: .failed
    )

    /// Partial parse with a very long title (truncation).
    public static let partial = Item(
        id: "a5-partial",
        url: "https://docs.example.dev/guides/very-long-guide",
        title:
            "An unusually long guide title that keeps going to check how rows truncate across two lines on small phones",
        excerpt: "Only part of this page could be extracted.",
        siteName: "Example Docs",
        wordCount: 9000,
        readingMinutes: 36,
        parseStatus: .partial,
        savedAt: ago(hours: 30),
        source: .import,
        tags: ["guides", "web"],
        offline: .availableRemote
    )

    /// PDF item, downloaded.
    public static let pdf = Item(
        id: "p1-pdf",
        url: "https://files.example.com/reports/annual-report-2026.pdf",
        title: "Annual report 2026",
        parseStatus: .ok,
        savedAt: ago(hours: 48),
        source: .share,
        tags: ["finance"],
        offline: .downloaded,
        kind: .pdf,
        fileName: "annual-report-2026.pdf",
        fileSize: 3_145_728
    )

    /// Archived, fully read.
    public static let archived = Item(
        id: "a6-archived",
        url: "https://www.example.com/recipes/sourdough",
        title: "A beginner's sourdough",
        excerpt: "Flour, water, salt and patience.",
        siteName: "Example Kitchen",
        wordCount: 1500,
        readingMinutes: 6,
        parseStatus: .ok,
        status: .archived,
        progress: 1,
        savedAt: ago(hours: 24 * 9),
        archivedAt: ago(hours: 24 * 2),
        lastReadAt: ago(hours: 24 * 2),
        source: .email,
        tags: ["recipes"],
        offline: .availableRemote
    )

    /// Archived favourite in another language.
    public static let archivedFavorite = Item(
        id: "a7-archived-fav",
        url: "https://przyklad.pl/artykul/sroka",
        title: "Sroka zwyczajna — ptak roku",
        excerpt: "Sroki należą do najinteligentniejszych ptaków.",
        siteName: "Przykład",
        lang: "pl",
        wordCount: 800,
        readingMinutes: 4,
        parseStatus: .ok,
        status: .archived,
        isFavorite: true,
        progress: 1,
        savedAt: ago(hours: 24 * 20),
        archivedAt: ago(hours: 24 * 15),
        source: .api,
        tags: ["birds"],
        offline: .downloaded
    )

    /// The default library: unread articles in every parse state, a PDF, archived items.
    public static let items: [Item] = [
        pendingParse, longRead, shortNews, paywalled, partial, pdf, archived, archivedFavorite,
    ]

    /// `count` generic unread articles (paging, scroll performance).
    public static func manyItems(_ count: Int) -> [Item] {
        (0..<count).map { index in
            Item(
                id: "bulk-\(index)",
                url: "https://example.com/bulk/\(index)",
                title: "Bulk article \(index + 1)",
                excerpt: "Generated fixture \(index + 1).",
                wordCount: 250 * (index % 20 + 1),
                readingMinutes: index % 20 + 1,
                parseStatus: .ok,
                savedAt: ago(hours: Double(index)),
                tags: index.isMultiple(of: 3) ? ["bulk"] : []
            )
        }
    }

    // MARK: Other state

    public static let tags: [TagCount] = [
        TagCount(name: "birds", count: 2), TagCount(name: "essays", count: 1), TagCount(name: "finance", count: 2),
        TagCount(name: "guides", count: 1), TagCount(name: "recipes", count: 1), TagCount(name: "science", count: 1),
        TagCount(name: "web", count: 2),
    ]

    public static let syncStatus = SyncStatus(
        phase: .idle,
        downloadedCount: 4,
        availableCount: 6,
        lastSyncAt: ago(hours: 0.2)
    )

    public static let syncingStatus = SyncStatus(
        phase: .downloading(done: 2, total: 5, currentTitle: longRead.title),
        pendingOps: 1,
        downloadedCount: 2,
        availableCount: 5,
        lastSyncAt: ago(hours: 0.2)
    )

    public static let uploads: [PdfUpload] = [
        PdfUpload(id: "u1", fileName: "contract.pdf", sizeBytes: 820_000, state: .uploading(progress: 0.4)),
        PdfUpload(id: "u2", fileName: "slides.pdf", sizeBytes: 12_000_000, state: .queued),
        PdfUpload(id: "u3", fileName: "huge-scan.pdf", sizeBytes: 80_000_000, state: .failed(.tooLarge)),
        PdfUpload(id: "u4", fileName: "invoice.pdf", sizeBytes: 90_000, state: .done(itemId: "p2", duplicate: false)),
    ]

    public static let runningImport = ImportJob(
        id: "job-1",
        status: .running,
        format: .pocketCsv,
        total: 1200,
        done: 480,
        skipped: 12,
        createdAt: ago(hours: 0.1),
        updatedAt: ago(hours: 0.01)
    )

    /// Sanitized reader HTML (body fragment) with a few anchorable blocks.
    public static func articleHtml(title: String) -> String {
        """
        <article><h1>\(title)</h1>
        <p>This is a fixture article body used by previews and tests.</p>
        <h2>A section</h2>
        <p>Magpies are among the most intelligent birds.</p>
        <blockquote>Save it now, read it later.</blockquote>
        <ul><li>One</li><li>Two</li></ul>
        </article>
        """
    }
}
