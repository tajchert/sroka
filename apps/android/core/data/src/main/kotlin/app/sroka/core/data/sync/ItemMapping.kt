package app.sroka.core.data.sync

import app.sroka.core.data.ops.statusFromWire
import app.sroka.core.database.entity.ItemEntity
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.ParseStatus
import app.sroka.core.model.UrlNormalizer
import app.sroka.core.network.ItemDto

/** Server row (api.md §4.1) → local row. Keeps the local `fts_rowid`; resets `resync_mark`. */
internal fun ItemDto.toEntity(existing: ItemEntity?): ItemEntity = ItemEntity(
    id = id,
    url = url,
    canonicalUrl = canonicalUrl ?: UrlNormalizer.normalize(url) ?: url,
    title = title,
    excerpt = excerpt,
    siteName = siteName,
    author = author,
    lang = lang,
    leadImageKey = leadImageKey,
    wordCount = wordCount,
    readingMinutes = readingMinutes,
    contentId = contentId,
    contentPrivate = contentPrivate,
    parseStatus = parseStatusFromWire(parseStatus, contentId),
    parseError = parseError,
    status = statusFromWire(status) ?: ItemStatus.UNREAD,
    isFavorite = isFavorite,
    progress = progress.coerceIn(0f, 1f),
    progressAnchor = progressAnchor,
    savedAt = savedAt,
    archivedAt = archivedAt,
    lastReadAt = lastReadAt,
    source = source,
    serverSeq = seq,
    ftsRowId = existing?.ftsRowId ?: 0,
    resyncMark = 0,
)

/** Unknown future values: readable content counts as OK, otherwise PENDING. */
internal fun parseStatusFromWire(value: String, contentId: String?): ParseStatus = when (value) {
    "pending" -> ParseStatus.PENDING
    "ok" -> ParseStatus.OK
    "partial" -> ParseStatus.PARTIAL
    "failed" -> ParseStatus.FAILED
    else -> if (contentId != null) ParseStatus.OK else ParseStatus.PENDING
}
