package app.sroka.core.database

import androidx.paging.PagingSource
import app.sroka.core.database.entity.PendingOpEntity
import app.sroka.core.database.entity.SearchRow
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.PendingChange
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PendingAndSearchDaoTest : DatabaseTestBase() {
    private val dao get() = db.itemDao()
    private var seq = 0

    private suspend fun op(itemId: String?, type: String) {
        db.pendingOpDao().enqueue(PendingOpEntity(opId = "op-${seq++}", itemId = itemId, type = type, payload = "{}", createdAt = 1))
    }

    private suspend fun pending(id: String) = page(q()).first { it.id == id }.toSummary().pendingChange

    @Test fun pendingChangeMapsNewestNonProgressOp() = runBlocking {
        for (id in listOf("a", "b", "c", "d", "e", "f")) dao.upsertItem(item(id))
        assertNull(pending("a"))
        op("a", "item.add"); assertEquals(PendingChange.SAVE, pending("a"))
        op("b", "item.tag"); assertEquals(PendingChange.TAGS, pending("b"))
        op("c", "item.setFavorite"); assertEquals(PendingChange.FAVORITE, pending("c"))
        op("d", "item.setStatus"); assertEquals(PendingChange.OTHER, pending("d"))
        op("e", "item.setTitle"); assertEquals(PendingChange.OTHER, pending("e"))
        // newest wins
        op("a", "item.setFavorite"); assertEquals(PendingChange.FAVORITE, pending("a"))
        // progress ops never flag, and do not hide an older real change
        op("f", "item.setProgress"); assertNull(pending("f"))
        op("a", "item.setProgress"); assertEquals(PendingChange.FAVORITE, pending("a"))
        // global tag ops have no item
        op(null, "tag.rename"); assertNull(pending("f"))
        // removing the ops clears the flag
        db.pendingOpDao().deleteForItem("a"); assertNull(pending("a"))
    }

    private suspend fun search(text: String, scope: String = "all"): List<SearchRow> {
        val match = FtsQuery.build(text)!!
        val source: PagingSource<Int, SearchRow> = when (scope) {
            "archive" -> dao.searchArchived(match)
            "fav" -> dao.searchFavorites(match)
            else -> dao.searchAll(match)
        }
        return (source.load(PagingSource.LoadParams.Refresh(null, 100, false)) as PagingSource.LoadResult.Page).data
    }

    private fun cols(r: SearchRow) = r.offsets!!.trim().split(' ').chunked(4).map { it[0].toInt() }.toSet()

    @Test fun searchTitleOnlyBodyOnlyAndBoth() = runBlocking {
        dao.upsertItem(item("t", title = "Zebra crossing", savedAt = 3))
        dao.upsertItem(item("b", title = "Plain", savedAt = 2))
        dao.setFtsBody("b", "A long story about a zebra that wandered far across the savanna.")
        dao.upsertItem(item("x", title = "Zebra facts", savedAt = 1))
        dao.setFtsBody("x", "Everything about the zebra stripes.")

        val hits = search("zebra")
        assertEquals(listOf("t", "b", "x"), hits.map { it.row.id }) // newest first
        assertEquals(setOf(0), cols(hits[0])) // title only
        assertEquals(setOf(4), cols(hits[1])) // body only
        assertEquals(setOf(0, 4), cols(hits[2])) // both
        assertTrue(hits[1].snippet!!.contains("zebra"))
    }

    @Test fun searchScopes() = runBlocking {
        dao.upsertItem(item("u", title = "Topic unread", savedAt = 4))
        dao.upsertItem(item("a", title = "Topic archived", status = ItemStatus.ARCHIVED, archivedAt = 1, savedAt = 3))
        dao.upsertItem(item("f", title = "Topic fav", favorite = true, savedAt = 2))
        dao.upsertItem(item("af", title = "Topic both", status = ItemStatus.ARCHIVED, archivedAt = 1, favorite = true, savedAt = 1))
        assertEquals(listOf("u", "a", "f", "af"), search("topic").map { it.row.id })
        assertEquals(listOf("a", "af"), search("topic", "archive").map { it.row.id })
        assertEquals(listOf("f", "af"), search("topic", "fav").map { it.row.id })
    }

    @Test fun searchCountMatchesScopes() = runBlocking {
        dao.upsertItem(item("u", title = "Topic unread", savedAt = 4))
        dao.upsertItem(item("a", title = "Topic archived", status = ItemStatus.ARCHIVED, archivedAt = 1, savedAt = 3))
        dao.upsertItem(item("f", title = "Topic fav", favorite = true, savedAt = 2))
        dao.upsertItem(item("af", title = "Topic both", status = ItemStatus.ARCHIVED, archivedAt = 1, favorite = true, savedAt = 1))
        dao.upsertItem(item("n", title = "Other", savedAt = 0))
        val match = FtsQuery.build("topic")!!
        assertEquals(4, dao.searchCountAll(match).first())
        assertEquals(2, dao.searchCountArchived(match).first())
        assertEquals(2, dao.searchCountFavorites(match).first())
    }

    @Test fun searchRowCarriesPendingChange() = runBlocking {
        dao.upsertItem(item("a", title = "Topic"))
        op("a", "item.add")
        assertEquals(PendingChange.SAVE, search("topic").single().row.toSummary().pendingChange)
    }
}
