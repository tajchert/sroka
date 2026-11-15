package app.sroka.feature.library.impl

import app.sroka.core.model.ItemKind
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.ItemSummary
import app.sroka.core.model.MatchIn
import app.sroka.core.model.OfflineState
import app.sroka.core.model.ParseStatus
import app.sroka.core.model.PendingChange
import app.sroka.core.model.SearchResult
import app.sroka.core.model.TagCount

private const val SavedAt = 1_768_473_000_000L // 2026-01-15T10:30:00Z

private fun summary(
    id: String,
    title: String,
    domain: String,
    minutes: Int? = 7,
    favorite: Boolean = false,
    progress: Float = 0f,
    parse: ParseStatus = ParseStatus.OK,
    offline: OfflineState = OfflineState.AVAILABLE_REMOTE,
    pending: PendingChange? = null,
    status: ItemStatus = ItemStatus.UNREAD,
    kind: ItemKind = ItemKind.ARTICLE,
    fileSize: Long? = null,
    thumbnailPath: String? = null,
    parseError: String? = null,
) = ItemSummary(
    parseError = parseError,
    id = id,
    displayTitle = title,
    domain = domain,
    excerpt = null,
    readingMinutes = minutes,
    status = status,
    isFavorite = favorite,
    progress = progress,
    parseStatus = parse,
    offline = offline,
    thumbnailPath = thumbnailPath,
    tags = emptyList(),
    savedAt = SavedAt,
    pendingChange = pending,
    kind = kind,
    fileSize = fileSize,
)

/** One row per row state (badge, progress, read, failed, preparing), plus a favorite and an ordinary row. */
internal val sampleItems: List<ItemSummary> = listOf(
    summary("i1", "How a magpie decides what to collect", "nature.example.org", 9, favorite = true, progress = 0.4f, offline = OfflineState.DOWNLOADED),
    summary("i2", "The slow web: why reading later still matters", "longreads.example.com", 14),
    summary("i3", "A saved link that has not reached the server yet", "draft.example.net", null, pending = PendingChange.SAVE),
    summary("i4", "Notes on tagging a growing library", "blog.example.dev", 5, progress = 1f, offline = OfflineState.DOWNLOADED, pending = PendingChange.TAGS),
    summary("i5", "Starring from the train, syncing later", "offline.example.io", 3, favorite = true, pending = PendingChange.FAVORITE),
    summary("i6", "A page that only half parsed", "partial.example.com", 6, parse = ParseStatus.PARTIAL),
    summary("i6p", "Behind a paywall: only the preview was saved", "paper.example.com", 4, parse = ParseStatus.PARTIAL, parseError = "paywalled"),
    summary("i7", "Downloading this one right now", "fetching.example.com", 11, offline = OfflineState.DOWNLOADING),
    summary("i8", "Available offline on this device", "saved.example.com", 8, offline = OfflineState.DOWNLOADED),
    summary("i9", "Couldn't read this page at all", "blocked.example.com", null, parse = ParseStatus.FAILED),
    summary("i10", "Just saved, the server is still parsing it", "fresh.example.com", null, parse = ParseStatus.PENDING, offline = OfflineState.NONE),
    summary("i11", "Finished reading this one last night", "done.example.com", 12, progress = 1f, offline = OfflineState.DOWNLOADED),
)

/** Library rows with PDFs: one downloaded, one waiting for its first sync, one with a first-page preview. */
internal val samplePdfItems: List<ItemSummary> = listOf(
    summary("p1", "Attention Is All You Need", "PDF", null, offline = OfflineState.DOWNLOADED, kind = ItemKind.PDF, fileSize = 2_411_724),
    summary(
        "p3", "Quarterly report Q3", "PDF", null, offline = OfflineState.DOWNLOADED, kind = ItemKind.PDF, fileSize = 512_000,
        thumbnailPath = "/nonexistent/thumbs/p3.webp", // no image in screenshots: shows the white page + badge
    ),
    summary("p2", "Tax return 2025.pdf", "PDF", null, kind = ItemKind.PDF, fileSize = 840_000, favorite = true),
    sampleItems[0],
    sampleItems[1],
)

internal val sampleSearchResults: List<SearchResult> = listOf(
    SearchResult(
        sampleItems[0], MatchIn.BOTH,
        "Magpies are known to collect shiny objects, but the story is more about curiosity than greed.",
        listOf(0..6, 49..53),
    ),
    SearchResult(
        sampleItems[1], MatchIn.TEXT,
        "Reading later only works when the library stays small enough to trust, like a magpie nest.",
        listOf(76..82),
    ),
    SearchResult(
        sampleItems[7].copy(status = ItemStatus.ARCHIVED), MatchIn.TITLE,
        null, emptyList(),
    ),
)

internal val sampleTags = listOf(
    TagCount("design", 4),
    TagCount("longreads", 12),
    TagCount("nature", 7),
    TagCount("tech", 21),
)

/** "Continue reading" strip: started, not finished. */
internal val sampleContinueReading: List<ItemSummary> = listOf(
    summary("c1", "How a magpie decides what to collect", "nature.example.org", 9, progress = 0.4f),
    summary("c2", "The slow web: why reading later still matters", "longreads.example.com", 14, progress = 0.72f),
    summary("c3", "A field guide to corvid intelligence", "birds.example.org", null, progress = 0.1f),
)

internal val sampleTopTags: List<String> = listOf("birds", "longreads", "rust", "design", "cooking")
