package app.sroka.core.database.entity

import androidx.room3.ColumnInfo
import androidx.room3.Embedded
import app.sroka.core.model.Item
import app.sroka.core.model.ItemKind
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.ItemSummary
import app.sroka.core.model.OfflineState
import app.sroka.core.model.ParseStatus
import app.sroka.core.model.PendingChange
import app.sroka.core.model.displayDomain

/** Separator of the `group_concat` tag list (ASCII unit separator). */
internal const val TAG_SEPARATOR = '\u001F'

/** Lightweight list-row projection (no full excerpt, tags via group_concat). */
data class ItemSummaryRow(
    val id: String,
    val title: String?,
    val url: String,
    val excerpt: String?,
    @ColumnInfo(name = "reading_minutes") val readingMinutes: Int?,
    val status: ItemStatus,
    @ColumnInfo(name = "is_favorite") val isFavorite: Boolean,
    val progress: Float,
    @ColumnInfo(name = "parse_status") val parseStatus: ParseStatus,
    @ColumnInfo(name = "saved_at") val savedAt: Long,
    @ColumnInfo(name = "content_id") val contentId: String?,
    @ColumnInfo(name = "file_content_id") val fileContentId: String?,
    @ColumnInfo(name = "file_state") val fileState: ContentState?,
    @ColumnInfo(name = "thumb_path") val thumbPath: String?,
    /** Tag names joined by [TAG_SEPARATOR], null if none. */
    val tags: String?,
    /** Type of the item's newest non-progress pending op, null if none (R6). */
    @ColumnInfo(name = "pending_type") val pendingType: String? = null,
    val kind: ItemKind = ItemKind.ARTICLE,
    @ColumnInfo(name = "file_size") val fileSize: Long? = null,
) {
    fun toSummary(): ItemSummary = ItemSummary(
        id = id,
        displayTitle = title?.takeIf { it.isNotBlank() } ?: displayDomain(url),
        domain = displayDomain(url),
        excerpt = excerpt,
        readingMinutes = readingMinutes,
        status = status,
        isFavorite = isFavorite,
        progress = progress,
        parseStatus = parseStatus,
        offline = deriveOffline(contentId, fileContentId, fileState),
        thumbnailPath = thumbPath,
        tags = splitTags(tags),
        savedAt = savedAt,
        pendingChange = pendingChangeOf(pendingType),
        kind = kind,
        fileSize = fileSize,
    )
}

/** Maps a `pending_ops.type` (wire op type) to the list flag (R6). */
fun pendingChangeOf(type: String?): PendingChange? = when (type) {
    null -> null
    "item.add" -> PendingChange.SAVE
    "item.tag" -> PendingChange.TAGS
    "item.setFavorite" -> PendingChange.FAVORITE
    else -> PendingChange.OTHER
}

/** Item with tags and offline state, for the reader / detail. */
data class ItemDetailRow(
    @Embedded val item: ItemEntity,
    @ColumnInfo(name = "file_content_id") val fileContentId: String?,
    @ColumnInfo(name = "file_state") val fileState: ContentState?,
    @ColumnInfo(name = "thumb_path") val thumbPath: String?,
    val tags: String?,
) {
    fun toItem(): Item = Item(
        id = item.id,
        url = item.url,
        canonicalUrl = item.canonicalUrl,
        title = item.title,
        excerpt = item.excerpt,
        siteName = item.siteName,
        author = item.author,
        lang = item.lang,
        leadImageKey = item.leadImageKey,
        wordCount = item.wordCount,
        readingMinutes = item.readingMinutes,
        contentId = item.contentId,
        contentPrivate = item.contentPrivate,
        parseStatus = item.parseStatus,
        parseError = item.parseError,
        status = item.status,
        isFavorite = item.isFavorite,
        progress = item.progress,
        progressAnchor = item.progressAnchor,
        savedAt = item.savedAt,
        archivedAt = item.archivedAt,
        lastReadAt = item.lastReadAt,
        source = item.source,
        tags = splitTags(tags),
        offline = deriveOffline(item.contentId, fileContentId, fileState),
        thumbnailPath = thumbPath,
        kind = item.kind,
        fileName = item.fileName,
        fileSize = item.fileSize,
    )
}

/**
 * Offline state per A4: no `contentId` on the item -> NONE; no file row or a row for another
 * content id (stale) -> AVAILABLE_REMOTE; otherwise the row state.
 */
fun deriveOffline(contentId: String?, fileContentId: String?, fileState: ContentState?): OfflineState = when {
    contentId == null -> OfflineState.NONE
    fileState == null || fileContentId != contentId -> OfflineState.AVAILABLE_REMOTE
    else -> when (fileState) {
        ContentState.QUEUED -> OfflineState.QUEUED
        ContentState.DOWNLOADING -> OfflineState.DOWNLOADING
        ContentState.DOWNLOADED -> OfflineState.DOWNLOADED
        ContentState.FAILED -> OfflineState.FAILED
    }
}

internal fun splitTags(joined: String?): List<String> =
    if (joined.isNullOrEmpty()) emptyList() else joined.split(TAG_SEPARATOR)

data class TagCountRow(val name: String, val count: Int)

data class CountsRow(val unread: Int, val archived: Int, val favorites: Int)

/** Item queued for download: [contentId] is the version to fetch. */
data class EligibleDownloadRow(
    @ColumnInfo(name = "item_id") val itemId: String,
    @ColumnInfo(name = "content_id") val contentId: String,
)

/** Search hit: list row plus FTS4 `snippet()` of the body and `offsets()` of all matches. */
data class SearchRow(
    @Embedded val row: ItemSummaryRow,
    val snippet: String?,
    /** FTS4 `offsets()`: groups of four ints (column, term, byte offset, size), space separated. */
    val offsets: String?,
)
