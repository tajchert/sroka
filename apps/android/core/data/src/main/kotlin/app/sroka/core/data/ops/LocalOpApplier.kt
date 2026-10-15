package app.sroka.core.data.ops

import app.sroka.core.database.dao.ItemDao
import app.sroka.core.database.entity.ItemEntity
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.MAX_TAGS_PER_ITEM
import app.sroka.core.model.ParseStatus
import app.sroka.core.model.UrlNormalizer
import app.sroka.core.model.tagKey
import javax.inject.Inject

/**
 * Applies the local effect of a [WireOp] to Room (DECISIONS A7). Used both for user writes and to
 * rebase un-pushed ops on top of freshly pulled rows (A8.2), so the two always agree.
 * Callers run it inside a write transaction.
 */
internal class LocalOpApplier @Inject constructor(private val itemDao: ItemDao) {

    /** Returns false when the target item does not exist locally (nothing changed). */
    suspend fun apply(op: WireOp): Boolean = when (op) {
        is WireOp.Add -> applyAdd(op)
        is WireOp.SetStatus -> ifExists(op.itemId) {
            itemDao.setStatus(op.itemId, op.status, if (op.status == ItemStatus.ARCHIVED) op.at else null)
        }
        is WireOp.SetFavorite -> ifExists(op.itemId) { itemDao.setFavorite(op.itemId, op.value) }
        is WireOp.SetProgress -> ifExists(op.itemId) {
            itemDao.setProgress(op.itemId, op.progress.coerceIn(0f, 1f), op.anchor, op.at)
        }
        is WireOp.SetTitle -> ifExists(op.itemId) { itemDao.setTitle(op.itemId, op.title?.takeIf { it.isNotBlank() }) }
        is WireOp.Tag -> ifExists(op.itemId) {
            val current = itemDao.tagNames(op.itemId)
            val key = tagKey(op.tag)
            val next = if (op.present) {
                if (current.any { tagKey(it) == key } || current.size >= MAX_TAGS_PER_ITEM) current else current + op.tag
            } else {
                current.filter { tagKey(it) != key }
            }
            if (next != current) itemDao.replaceTags(op.itemId, next)
        }
        is WireOp.Delete -> ifExists(op.itemId) { itemDao.deleteItem(op.itemId) }
        is WireOp.Refresh -> ifExists(op.itemId) { itemDao.setParseStatus(op.itemId, ParseStatus.PENDING) }
        is WireOp.TagRename -> {
            itemDao.renameTag(tagKey(op.from), op.to)
            true
        }
        is WireOp.TagDelete -> {
            itemDao.deleteTag(tagKey(op.tag))
            true
        }
    }

    /** New item, or a re-add of an existing one (api.md §8.2 "readd"). */
    private suspend fun applyAdd(op: WireOp.Add): Boolean {
        val existing = itemDao.getItem(op.itemId)
        if (existing == null) {
            val canonical = UrlNormalizer.normalize(op.url) ?: return false
            itemDao.upsertItemWithTags(
                ItemEntity(
                    id = op.itemId,
                    url = op.url,
                    canonicalUrl = canonical,
                    title = op.title?.takeIf { it.isNotBlank() },
                    excerpt = null,
                    siteName = null,
                    author = null,
                    lang = null,
                    leadImageKey = null,
                    wordCount = null,
                    readingMinutes = null,
                    contentId = null,
                    contentPrivate = false,
                    parseStatus = ParseStatus.PENDING,
                    parseError = null,
                    status = ItemStatus.UNREAD,
                    isFavorite = false,
                    progress = 0f,
                    progressAnchor = null,
                    savedAt = op.savedAt,
                    archivedAt = null,
                    lastReadAt = null,
                    source = op.source,
                    serverSeq = null,
                ),
                unionTags(emptyList(), op.tags),
            )
        } else {
            itemDao.upsertItemWithTags(
                existing.copy(
                    status = ItemStatus.UNREAD,
                    archivedAt = null,
                    savedAt = maxOf(existing.savedAt, op.savedAt),
                    title = existing.title ?: op.title?.takeIf { it.isNotBlank() },
                ),
                unionTags(itemDao.tagNames(op.itemId), op.tags),
            )
        }
        return true
    }

    private suspend inline fun ifExists(itemId: String, block: () -> Unit): Boolean {
        if (itemDao.getItem(itemId) == null) return false
        block()
        return true
    }
}

/** [current] plus [added] tags not already present (by tag key), capped at [MAX_TAGS_PER_ITEM]. */
internal fun unionTags(current: List<String>, added: List<String>): List<String> {
    val keys = current.mapTo(HashSet()) { tagKey(it) }
    val out = current.toMutableList()
    for (name in added) {
        if (out.size >= MAX_TAGS_PER_ITEM) break
        if (name.isNotBlank() && keys.add(tagKey(name))) out += name
    }
    return out
}
