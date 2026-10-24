package app.sroka.feature.library.impl

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
    parse: ParseStatus = ParseStatus.OK,
    offline: OfflineState = OfflineState.AVAILABLE_REMOTE,
    pending: PendingChange? = null,
    status: ItemStatus = ItemStatus.UNREAD,
) = ItemSummary(
    id = id,
    displayTitle = title,
    domain = domain,
    excerpt = null,
    readingMinutes = minutes,
    status = status,
    isFavorite = favorite,
    progress = 0f,
    parseStatus = parse,
    offline = offline,
    thumbnailPath = null,
    tags = emptyList(),
    savedAt = SavedAt,
    pendingChange = pending,
)

/** One row per status line (R6), plus a favourite and an ordinary row. */
internal val sampleItems: List<ItemSummary> = listOf(
    summary("i1", "How a magpie decides what to collect", "nature.example.org", 9, favorite = true, offline = OfflineState.DOWNLOADED),
    summary("i2", "The slow web: why reading later still matters", "longreads.example.com", 14),
    summary("i3", "A saved link that has not reached the server yet", "draft.example.net", null, pending = PendingChange.SAVE),
    summary("i4", "Notes on tagging a growing library", "blog.example.dev", 5, pending = PendingChange.TAGS),
    summary("i5", "Starring from the train, syncing later", "offline.example.io", 3, favorite = true, pending = PendingChange.FAVORITE),
    summary("i6", "A page that only half parsed", "partial.example.com", 6, parse = ParseStatus.PARTIAL),
    summary("i7", "Downloading this one right now", "fetching.example.com", 11, offline = OfflineState.DOWNLOADING),
    summary("i8", "Available offline on this device", "saved.example.com", 8, offline = OfflineState.DOWNLOADED),
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
