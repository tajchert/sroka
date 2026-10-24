package app.sroka.core.testing

import app.sroka.core.model.Item
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.OfflineState
import app.sroka.core.model.ParseStatus
import app.sroka.core.model.PendingChange

/** Builds an [Item] with sensible defaults; override only what a test cares about. */
fun testItem(
    id: String = "0192f3c4-0000-7000-8000-000000000001",
    url: String = "https://example.com/$id",
    title: String? = "Article $id",
    excerpt: String? = "Excerpt of $id",
    status: ItemStatus = ItemStatus.UNREAD,
    isFavorite: Boolean = false,
    progress: Float = 0f,
    tags: List<String> = emptyList(),
    savedAt: Long = 1_760_400_000_000L,
    wordCount: Int? = 1000,
    readingMinutes: Int? = 5,
    contentId: String? = "c-$id",
    parseStatus: ParseStatus = ParseStatus.OK,
    offline: OfflineState = OfflineState.DOWNLOADED,
    pendingChange: PendingChange? = null,
): Item = Item(
    id = id,
    url = url,
    canonicalUrl = url,
    title = title,
    excerpt = excerpt,
    siteName = "Example",
    author = null,
    lang = "en",
    leadImageKey = null,
    wordCount = wordCount,
    readingMinutes = readingMinutes,
    contentId = contentId,
    contentPrivate = false,
    parseStatus = parseStatus,
    parseError = null,
    status = status,
    isFavorite = isFavorite,
    progress = progress,
    progressAnchor = null,
    savedAt = savedAt,
    archivedAt = if (status == ItemStatus.ARCHIVED) savedAt else null,
    lastReadAt = null,
    source = "share",
    tags = tags,
    offline = offline,
    thumbnailPath = null,
    pendingChange = pendingChange,
)
