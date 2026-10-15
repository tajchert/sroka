package app.sroka.core.data.sync

import android.util.Log
import app.sroka.core.common.Clock
import app.sroka.core.common.di.Dispatcher
import app.sroka.core.common.di.SrokaDispatchers
import app.sroka.core.data.content.ContentPaths
import app.sroka.core.data.ops.LocalOpApplier
import app.sroka.core.data.ops.WireOp
import app.sroka.core.data.tx
import app.sroka.core.database.SrokaDatabase
import app.sroka.core.database.dao.ItemDao
import app.sroka.core.database.dao.PendingOpDao
import app.sroka.core.database.dao.SyncStateDao
import app.sroka.core.database.entity.PendingOpEntity
import app.sroka.core.database.entity.TagEntity
import app.sroka.core.datastore.SessionStore
import app.sroka.core.model.SyncErrorKind
import app.sroka.core.model.newUuidV7
import app.sroka.core.model.tagKey
import app.sroka.core.network.ApiResult
import app.sroka.core.network.PullResponseDto
import app.sroka.core.network.PushResponseDto
import app.sroka.core.network.SrokaApi
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import javax.inject.Inject
import javax.inject.Singleton

sealed interface SyncOutcome {
    data class Success(val pulledItems: Int) : SyncOutcome
    data class Failure(val kind: SyncErrorKind) : SyncOutcome
}

/**
 * Push + pull (DECISIONS A8, api.md §7). Single-flight: concurrent callers wait for the mutex.
 * Run only from `SyncWorker` (and tests).
 */
@Singleton
class SyncEngine @Inject internal constructor(
    private val db: SrokaDatabase,
    private val itemDao: ItemDao,
    private val pendingOpDao: PendingOpDao,
    private val syncStateDao: SyncStateDao,
    private val api: SrokaApi,
    private val sessionStore: SessionStore,
    private val applier: LocalOpApplier,
    private val paths: ContentPaths,
    private val clock: Clock,
    @Dispatcher(SrokaDispatchers.IO) private val io: CoroutineDispatcher,
) {
    private val mutex = Mutex()

    suspend fun sync(): SyncOutcome = mutex.withLock {
        val outcome = runSync()
        syncStateDao.update { state ->
            when (outcome) {
                is SyncOutcome.Success -> state.copy(lastSuccessAt = clock.now(), lastError = null)
                is SyncOutcome.Failure -> state.copy(lastError = outcome.kind.name)
            }
        }
        outcome
    }

    /** Runs [block] while no sync is in progress (sign-out wipe). */
    suspend fun <T> exclusive(block: suspend () -> T): T = mutex.withLock { block() }

    private suspend fun runSync(): SyncOutcome {
        val deviceId = sessionStore.deviceId()
        push(deviceId)?.let { return SyncOutcome.Failure(it) }

        // A pass that starts at cursor 0 is a "full" pass: the server never answers 410 for its later
        // pages (api.md §7.2), and rows not seen by the end of it are dropped (finishFullResync).
        syncStateDao.get().let { st ->
            if (st.cursor == 0L && !st.fullResync) syncStateDao.update { it.copy(fullResync = true) }
        }
        var pulled = 0
        var restarted = false
        while (true) {
            val state = syncStateDao.get()
            val page = when (val r = api.pull(state.cursor, PULL_LIMIT, full = state.fullResync)) {
                is ApiResult.Success -> r.value
                is ApiResult.NetworkError -> return SyncOutcome.Failure(SyncErrorKind.NETWORK)
                is ApiResult.HttpError -> {
                    if (r.status == 410 && !restarted) {
                        // A8.3: everything local is suspect; re-pull from 0 and drop what does not come back.
                        restarted = true
                        startFullResync()
                        push(deviceId)?.let { return SyncOutcome.Failure(it) }
                        continue
                    }
                    return SyncOutcome.Failure(errorKind(r))
                }
            }
            pulled += page.items.size
            applyPage(page)
            if (!page.hasMore) break
        }
        if (syncStateDao.get().fullResync) finishFullResync()
        return SyncOutcome.Success(pulled)
    }

    // ---- push -----------------------------------------------------------------------------

    /** Pushes every pending op in batches; returns the failure kind or null on success. */
    private suspend fun push(deviceId: String): SyncErrorKind? {
        while (true) {
            val batch = pendingOpDao.batch(PUSH_BATCH)
            if (batch.isEmpty()) return null
            val parsed = batch.map { it to parseOrNull(it.payload) }
            val corrupt = parsed.filter { it.second == null }.map { it.first.opId }
            if (corrupt.isNotEmpty()) {
                pendingOpDao.deleteByOpIds(corrupt)
                continue
            }
            val ops = parsed.map { it.second!! }
            when (val r = api.push(deviceId, ops)) {
                is ApiResult.Success -> {
                    val progressed = applyPushResponse(batch, r.value)
                    if (!progressed) {
                        pendingOpDao.markAttempted(batch.map { it.opId }, "not_acknowledged")
                        return SyncErrorKind.SERVER
                    }
                }
                is ApiResult.NetworkError -> return SyncErrorKind.NETWORK
                is ApiResult.HttpError -> {
                    pendingOpDao.markAttempted(batch.map { it.opId }, "http_${r.status}")
                    return errorKind(r)
                }
            }
        }
    }

    /** Applies `applied`/`rejected`/`aliases` in one transaction. Returns false if no op was acknowledged. */
    private suspend fun applyPushResponse(batch: List<PendingOpEntity>, response: PushResponseDto): Boolean {
        val byOpId = batch.associateBy { it.opId }
        val acknowledged = (response.applied + response.rejected.map { it.opId }).filter { it in byOpId }
        val removedItems = mutableSetOf<String>()
        db.tx {
            // A re-save of a URL whose item was deleted elsewhere: keep its queued ops and re-key them
            // to a new item instead of dropping the user's save (api.md §8.2.6).
            val rekeyIds = mutableSetOf<String>()
            val keepQueued = mutableSetOf<String>()
            for (rejected in response.rejected) {
                val op = byOpId[rejected.opId] ?: continue
                val id = op.itemId ?: continue
                if (rejected.reason != REJECT_ITEM_DELETED || !ContentPaths.isSafeId(id)) continue
                if (id in rekeyIds || hasQueuedAdd(id)) {
                    rekeyIds += id
                    keepQueued += rejected.opId
                }
            }
            pendingOpDao.deleteByOpIds(acknowledged.filter { it !in keepQueued })
            for (id in rekeyIds) {
                rekeyReAdd(id)
                removedItems += id
            }
            for (rejected in response.rejected) {
                val op = byOpId[rejected.opId] ?: continue
                Log.w(TAG, "op ${op.type} rejected: ${rejected.reason}")
                val id = op.itemId ?: continue
                if (!ContentPaths.isSafeId(id) || id in rekeyIds) continue
                if (rejected.reason == REJECT_ITEM_DELETED) {
                    pendingOpDao.deleteForItem(id)
                    itemDao.deleteItem(id)
                    removedItems += id
                } else if (op.type == WireOp.ADD && itemDao.getItem(id)?.serverSeq == null) {
                    // The server will never accept this add: do not keep a local-only orphan.
                    pendingOpDao.deleteForItem(id)
                    itemDao.deleteItem(id)
                    removedItems += id
                }
            }
            for ((clientId, existingId) in response.aliases) {
                if (clientId == existingId) continue
                if (!ContentPaths.isSafeId(clientId) || !ContentPaths.isSafeId(existingId)) continue
                // The server merged our add into an existing item: re-target queued ops. If the
                // canonical row is not local yet, re-key ours so the item survives a failed pull
                // (the pull overwrites it); otherwise drop the duplicate.
                pendingOpDao.reassignItem(clientId, existingId)
                if (itemDao.getItem(existingId) != null) itemDao.deleteItem(clientId) else itemDao.rekeyItem(clientId, existingId)
                removedItems += clientId
            }
        }
        if (removedItems.isNotEmpty()) withContext(io) { removedItems.forEach(paths::deleteItemFiles) }
        return acknowledged.isNotEmpty()
    }

    private suspend fun hasQueuedAdd(itemId: String): Boolean =
        pendingOpDao.forItem(itemId).any { WireOp.parse(it.payload) is WireOp.Add }

    /**
     * An item that was tombstoned on the server still has a queued `item.add` (the user re-saved the
     * URL): move its queued ops to a fresh item id with fresh op ids, drop the old local row and
     * rebuild the new one from the ops. Returns false (nothing changed) when no add is queued.
     */
    private suspend fun rekeyReAdd(oldId: String): Boolean {
        val adds = pendingOpDao.forItem(oldId).filter { WireOp.parse(it.payload) is WireOp.Add }
        if (adds.isEmpty()) return false
        val now = clock.now()
        val newId = newUuidV7(now)
        pendingOpDao.reassignItem(oldId, newId)
        // The server already acknowledged (rejected) the old add's op id.
        adds.forEach { pendingOpDao.rewriteOpId(it.opId, newUuidV7(now)) }
        itemDao.deleteItem(oldId)
        for (op in pendingOpDao.forItem(newId)) WireOp.parse(op.payload)?.let { applier.apply(it) }
        return true
    }

    // ---- pull -----------------------------------------------------------------------------

    /** One page = one transaction together with its cursor (A8.2), then local un-pushed ops are re-applied. */
    private suspend fun applyPage(page: PullResponseDto) {
        // Ids from the server become file names and WebView URLs: drop anything unexpected.
        val items = page.items.filter { dto ->
            ContentPaths.isSafeId(dto.id).also { if (!it) Log.w(TAG, "ignoring item with unsafe id") }
        }
        val deletedItems = page.deleted.items.filter { ContentPaths.isSafeId(it) }
        db.tx {
            for (dto in items) {
                itemDao.upsertItemWithTags(dto.toEntity(itemDao.getItem(dto.id)), dto.tags)
            }
            if (page.deleted.tags.isNotEmpty()) itemDao.deleteTagRowsById(page.deleted.tags)
            for (tag in page.tags) {
                val key = tagKey(tag.name)
                itemDao.deleteTagRowByKey(key)
                itemDao.upsertTagRows(listOf(TagEntity(tag.id, tag.name, key)))
            }
            for (id in deletedItems) {
                if (!rekeyReAdd(id)) {
                    pendingOpDao.deleteForItem(id)
                    itemDao.deleteItem(id)
                }
            }
            rebase(items.map { it.id })
            syncStateDao.update { it.copy(cursor = page.cursor) }
        }
        if (deletedItems.isNotEmpty()) withContext(io) { deletedItems.forEach(paths::deleteItemFiles) }
    }

    /**
     * Re-applies queued (un-pushed) ops of [itemIds] and every queued tag-level op, so older server
     * state does not hide local edits. A page may carry only `tags`, hence no early return.
     */
    private suspend fun rebase(itemIds: List<String>) {
        val chunks = itemIds.chunked(SQL_CHUNK)
        if (chunks.isEmpty()) {
            reapply(pendingOpDao.globalOps())
            return
        }
        chunks.forEachIndexed { index, chunk ->
            // Tag-level ops (item_id NULL) are applied once, with the first chunk.
            reapply(if (index == 0) pendingOpDao.forItemsOrGlobal(chunk) else pendingOpDao.forItems(chunk))
        }
    }

    private suspend fun reapply(ops: List<PendingOpEntity>) {
        for (op in ops) WireOp.parse(op.payload)?.let { applier.apply(it) }
    }

    // ---- full resync (410) ----------------------------------------------------------------

    private suspend fun startFullResync() = db.tx {
        itemDao.markAllForResync()
        syncStateDao.update { it.copy(cursor = 0, fullResync = true) }
    }

    private suspend fun finishFullResync() {
        val removed = db.tx {
            val ids = itemDao.deleteStaleMarkedItems()
            itemDao.clearResyncMarks()
            syncStateDao.update { it.copy(fullResync = false) }
            ids
        }
        if (removed.isNotEmpty()) withContext(io) { removed.forEach(paths::deleteItemFiles) }
    }

    // ---- helpers --------------------------------------------------------------------------

    private suspend fun errorKind(error: ApiResult.HttpError): SyncErrorKind = when (error.status) {
        401 -> {
            sessionStore.markExpired()
            SyncErrorKind.AUTH
        }
        else -> SyncErrorKind.SERVER
    }

    private fun parseOrNull(payload: String): JsonObject? =
        runCatching { JSON.parseToJsonElement(payload) as JsonObject }.getOrNull()

    private companion object {
        const val TAG = "SrokaSync"
        const val PUSH_BATCH = 500
        const val PULL_LIMIT = 500
        const val SQL_CHUNK = 500
        const val REJECT_ITEM_DELETED = "item_deleted"
        val JSON = Json
    }
}
