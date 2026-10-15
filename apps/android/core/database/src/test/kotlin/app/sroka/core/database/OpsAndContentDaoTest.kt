package app.sroka.core.database

import app.sroka.core.database.entity.ContentFileEntity
import app.sroka.core.database.entity.ContentState
import app.sroka.core.database.entity.PendingOpEntity
import app.sroka.core.model.ItemStatus
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

internal fun op(id: String, itemId: String?, type: String, payload: String = "{\"itemId\":\"$itemId\"}") =
    PendingOpEntity(opId = id, itemId = itemId, type = type, payload = payload, createdAt = 1)

class OpsAndContentDaoTest : DatabaseTestBase() {
    private val ops get() = db.pendingOpDao()
    private val files get() = db.contentFileDao()
    private val items get() = db.itemDao()

    @Test fun coalescesByItemAndTypeOnly() = runBlocking {
        ops.enqueue(op("1", "a", "item.setProgress"))
        ops.enqueue(op("2", "b", "item.setProgress"))
        ops.enqueue(op("3", "a", "item.setStatus"))
        ops.enqueue(op("4", "a", "item.setProgress"))
        ops.enqueue(op("5", "a", "item.tag"))
        ops.enqueue(op("6", "a", "item.tag"))
        assertEquals(listOf("2", "3", "4", "5", "6"), ops.batch(100).map { it.opId })
        assertEquals(listOf("2", "3"), ops.batch(2).map { it.opId })
        ops.deleteByOpIds(listOf("2", "3"))
        assertEquals(3, ops.observeCount().first())
    }

    @Test fun reassignRewritesRowAndPayload() = runBlocking {
        ops.enqueue(op("1", "client", "item.tag"))
        ops.reassignItem("client", "server")
        val o = ops.batch(10).single()
        assertEquals("server", o.itemId)
        assertTrue(o.payload.contains("\"itemId\":\"server\""))
    }

    @Test fun markAttemptedAndDeleteForItem() = runBlocking {
        ops.enqueue(op("1", "a", "item.tag"))
        ops.markAttempted(listOf("1"), "net")
        assertEquals(1, ops.batch(1).single().attempts)
        ops.deleteForItem("a")
        assertEquals(0, ops.count())
    }

    @Test fun syncStateDefaultsAndUpdate() = runBlocking {
        assertEquals(0L, db.syncStateDao().get().cursor)
        db.syncStateDao().update { it.copy(cursor = 42, fullResync = true) }
        db.syncStateDao().update { it.copy(lastSuccessAt = 7) }
        val s = db.syncStateDao().get()
        assertEquals(Triple(42L, 7L, true), Triple(s.cursor, s.lastSuccessAt, s.fullResync))
    }

    @Test fun eligibleDownloadsFollowA9Order() = runBlocking {
        items.upsertItem(item("old", savedAt = 100))
        items.upsertItem(item("new", savedAt = 300))
        items.upsertItem(item("fav-archived", savedAt = 200, status = ItemStatus.ARCHIVED, favorite = true))
        items.upsertItem(item("archived", savedAt = 250, status = ItemStatus.ARCHIVED))
        items.upsertItem(item("nocontent", savedAt = 400, contentId = null))
        items.upsertItem(item("done", savedAt = 500))
        items.upsertItem(item("stale", savedAt = 150))
        items.upsertItem(item("failed", savedAt = 120))
        items.upsertItem(item("failed5", savedAt = 130))
        items.upsertItem(item("downloading", savedAt = 140))
        files.upsert(ContentFileEntity("done", "c-done", ContentState.DOWNLOADED))
        files.upsert(ContentFileEntity("stale", "OLD", ContentState.DOWNLOADED))
        files.upsert(ContentFileEntity("failed", "c-failed", ContentState.FAILED, attempts = 4))
        files.upsert(ContentFileEntity("failed5", "c-failed5", ContentState.FAILED, attempts = 5))
        files.upsert(ContentFileEntity("downloading", "c-downloading", ContentState.DOWNLOADING))
        assertEquals(
            listOf("new", "fav-archived", "stale", "failed", "old"),
            files.eligibleForDownload().map { it.itemId },
        )
        assertEquals(listOf("new", "fav-archived"), files.eligibleForDownload(limit = 2).map { it.itemId })
        assertEquals(5, files.observeEligibleCount().first())
        assertEquals(1, files.observeDownloadedCount().first()) // "stale" does not count
        files.resetDownloading()
        assertEquals(ContentState.QUEUED, files.get("downloading")!!.state)
        assertTrue(files.eligibleForDownload().any { it.itemId == "downloading" })
    }

    @Test fun evictionCandidatesAndTotals() = runBlocking {
        items.upsertItem(item("oldArch", status = ItemStatus.ARCHIVED, archivedAt = 100))
        items.upsertItem(item("freshArch", status = ItemStatus.ARCHIVED, archivedAt = 900))
        items.upsertItem(item("favArch", status = ItemStatus.ARCHIVED, archivedAt = 100, favorite = true))
        items.upsertItem(item("unread"))
        for (id in listOf("oldArch", "freshArch", "favArch", "unread")) {
            files.upsert(ContentFileEntity(id, "c-$id", ContentState.DOWNLOADED, bytes = 10, thumbPath = "/t/$id"))
        }
        assertEquals(listOf("oldArch"), files.evictionCandidates(archivedBefore = 500))
        assertEquals(40L, files.totalBytes())
        assertEquals(4, files.thumbPaths().size)
        files.deleteAll()
        assertEquals(0L, files.totalBytes())
    }
}
