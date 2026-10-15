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

        var pulled = 0
        var restarted = false
        while (true) {
            val state = syncStateDao.get()
            val page = when (val r = api.pull(state.cursor, PULL_LIMIT)) {
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
            pendingOpDao.deleteByOpIds(acknowledged)
            for (rejected in response.rejected) {
                val op = byOpId[rejected.opId] ?: continue
                Log.w(TAG, "op ${op.type} rejected: ${rejected.reason}")
                if (rejected.reason == REJECT_ITEM_DELETED && op.itemId != null) {
                    pendingOpDao.deleteForItem(op.itemId!!)
                    itemDao.deleteItem(op.itemId!!)
                    removedItems += op.itemId!!
                }
            }
            for ((clientId, existingId) in response.aliases) {
                if (clientId == existingId) continue
                // The server merged our add into an existing item: re-target queued ops and drop the
                // local duplicate row; the canonical row arrives with the following pull.
                pendingOpDao.reassignItem(clientId, existingId)
                itemDao.deleteItem(clientId)
                removedItems += clientId
            }
        }
        if (removedItems.isNotEmpty()) withContext(io) { removedItems.forEach(paths::deleteItemFiles) }
        return acknowledged.isNotEmpty()
    }

    // ---- pull -----------------------------------------------------------------------------

    /** One page = one transaction together with its cursor (A8.2), then local un-pushed ops are re-applied. */
    private suspend fun applyPage(page: PullResponseDto) {
        val deletedItems = page.deleted.items
        db.tx {
            for (dto in page.items) {
                itemDao.upsertItemWithTags(dto.toEntity(itemDao.getItem(dto.id)), dto.tags)
            }
            if (page.deleted.tags.isNotEmpty()) itemDao.deleteTagRowsById(page.deleted.tags)
            for (tag in page.tags) {
                val key = tagKey(tag.name)
                itemDao.deleteTagRowByKey(key)
                itemDao.upsertTagRows(listOf(TagEntity(tag.id, tag.name, key)))
            }
            for (id in deletedItems) {
                pendingOpDao.deleteForItem(id)
                itemDao.deleteItem(id)
            }
            rebase(page.items.map { it.id })
            syncStateDao.update { it.copy(cursor = page.cursor) }
        }
        if (deletedItems.isNotEmpty()) withContext(io) { deletedItems.forEach(paths::deleteItemFiles) }
    }

    /** Re-applies queued (un-pushed) ops of [itemIds] so older server state does not hide local edits. */
    private suspend fun rebase(itemIds: List<String>) {
        if (itemIds.isEmpty()) return
        for (chunk in itemIds.chunked(SQL_CHUNK)) {
            for (op in pendingOpDao.forItems(chunk)) {
                WireOp.parse(op.payload)?.let { applier.apply(it) }
            }
        }
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
