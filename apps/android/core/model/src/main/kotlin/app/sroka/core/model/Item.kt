package app.sroka.core.model

/**
 * A saved article as the app sees it (DECISIONS A3). Mirrors the wire `Item` (api.md §4.1) plus
 * local state: [offline] (derived from downloaded content) and [thumbnailPath] (local file).
 */
data class Item(
    val id: String,
    val url: String,
    val canonicalUrl: String,
    val title: String?,
    val excerpt: String?,
    val siteName: String?,
    val author: String?,
    val lang: String?,
    val leadImageKey: String?,
    val wordCount: Int?,
    val readingMinutes: Int?,
    /** Non-null once the server has a readable content package. */
    val contentId: String?,
    val contentPrivate: Boolean,
    val parseStatus: ParseStatus,
    /** Short server reason such as `http_404`, `timeout`; only meaningful when [parseStatus] is FAILED. */
    val parseError: String?,
    val status: ItemStatus,
    val isFavorite: Boolean,
    /** Reading progress 0..1. */
    val progress: Float,
    /** Index of the first visible block element (api.md §4.1 `progressAnchor`). */
    val progressAnchor: Int?,
    val savedAt: Long,
    val archivedAt: Long?,
    val lastReadAt: Long?,
    val source: String?,
    val tags: List<String>,
    val offline: OfflineState,
    /** Absolute path of the local thumbnail file, or null. */
    val thumbnailPath: String?,
    /** Newest un-pushed local change (R6); only filled by list projections. */
    val pendingChange: PendingChange? = null,
    /** `article` or `pdf`; a PDF item's content is the original file (no reader view). */
    val kind: ItemKind = ItemKind.ARTICLE,
    /** Original file name of a PDF item. */
    val fileName: String? = null,
    /** Size in bytes of the original PDF file. */
    val fileSize: Long? = null,
) {
    /** Host without a leading `www.`, for display. */
    val domain: String get() = displayDomain(url)

    /** Title for display: the item title or, if absent, the [domain]. */
    val displayTitle: String get() = title?.takeIf { it.isNotBlank() } ?: domain
}

/** Lightweight list-row projection of [Item] (DECISIONS A3/A4). */
data class ItemSummary(
    val id: String,
    val displayTitle: String,
    val domain: String,
    val excerpt: String?,
    val readingMinutes: Int?,
    val status: ItemStatus,
    val isFavorite: Boolean,
    val progress: Float,
    val parseStatus: ParseStatus,
    val offline: OfflineState,
    val thumbnailPath: String?,
    val tags: List<String>,
    val savedAt: Long,
    /** Newest un-pushed local change to this item, ignoring reading progress (R6). */
    val pendingChange: PendingChange? = null,
    val kind: ItemKind = ItemKind.ARTICLE,
    val fileSize: Long? = null,
)

/** Kind of local change waiting in `pending_ops` (R6). */
enum class PendingChange { SAVE, TAGS, FAVORITE, OTHER }

/** Hostname of [url] without a leading `www.`; empty if [url] has no parsable host. */
fun displayDomain(url: String): String =
    UrlNormalizer.hostOf(url)?.removePrefix("www.").orEmpty()

/** List-row projection of this item. */
fun Item.toSummary(): ItemSummary = ItemSummary(
    id = id,
    displayTitle = displayTitle,
    domain = domain,
    excerpt = excerpt,
    readingMinutes = readingMinutes,
    status = status,
    isFavorite = isFavorite,
    progress = progress,
    parseStatus = parseStatus,
    offline = offline,
    thumbnailPath = thumbnailPath,
    tags = tags,
    savedAt = savedAt,
    pendingChange = pendingChange,
    kind = kind,
    fileSize = fileSize,
)
