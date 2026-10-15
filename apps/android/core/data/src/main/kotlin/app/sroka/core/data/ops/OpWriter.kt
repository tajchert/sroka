package app.sroka.core.data.ops

import app.sroka.core.common.Clock
import app.sroka.core.data.tx
import app.sroka.core.database.SrokaDatabase
import app.sroka.core.database.dao.PendingOpDao
import app.sroka.core.database.entity.PendingOpEntity
import app.sroka.core.model.newUuidV7
import javax.inject.Inject

/**
 * Local-first write path (DECISIONS A7): in ONE Room transaction, applies each op's local effect and
 * queues its wire JSON in `pending_ops` (coalesced by [PendingOpDao.enqueue]). Ops whose target item
 * does not exist are dropped.
 */
internal class OpWriter @Inject constructor(
    private val db: SrokaDatabase,
    private val applier: LocalOpApplier,
    private val pendingOpDao: PendingOpDao,
    private val clock: Clock,
) {
    fun newOpId(now: Long): String = newUuidV7(now)

    /** [build] runs inside the transaction with `now` and returns the ops; true if any op was queued. */
    suspend fun write(build: suspend (now: Long) -> List<WireOp>): Boolean {
        val now = clock.now()
        return db.tx {
            var queued = false
            for (op in build(now)) {
                if (applier.apply(op)) {
                    pendingOpDao.enqueue(op.toEntity(now))
                    queued = true
                }
            }
            queued
        }
    }
}

internal fun WireOp.toEntity(now: Long) = PendingOpEntity(
    opId = opId,
    itemId = itemId,
    type = type,
    payload = payload(),
    createdAt = now,
)
