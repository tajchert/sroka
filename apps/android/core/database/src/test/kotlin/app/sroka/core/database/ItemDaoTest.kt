package app.sroka.core.database

import androidx.room3.withWriteTransaction
import app.sroka.core.database.entity.ContentFileEntity
import app.sroka.core.database.entity.ContentState
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.OfflineState
import app.sroka.core.model.SortOrder
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ItemDaoTest : DatabaseTestBase() {
    private val dao get() = db.itemDao()

    @Test fun ftsInsertUpdateDeleteSearch() = runBlocking {
        dao.upsertItemWithTags(item("a", title = "Kotlin coroutines guide", excerpt = "flows", siteName = "Blog"), listOf("Dev"))
        dao.upsertItem(item("b", title = "Café résumé", savedAt = 2_000))
        assertEquals(listOf("a"), ids(q(search = "corout")))
        assertEquals(listOf("a"), ids(q(search = "kotlin guide")))
        assertEquals(listOf("a"), ids(q(search = "dev")))        // tags are indexed
        assertEquals(listOf("a"), ids(q(search = "blog")))       // site name
        assertEquals(listOf("b"), ids(q(search = "cafe resume")))     // diacritics folded
        assertEquals(emptyList<String>(), ids(q(search = "nothing")))

        dao.setTitle("a", "Rust ownership")
        assertEquals(emptyList<String>(), ids(q(search = "kotlin")))
        assertEquals(listOf("a"), ids(q(search = "rust")))
        assertEquals(listOf("a"), ids(q(search = "dev")))        // tags kept across title change

        dao.replaceTags("a", listOf("Ops"))
        assertEquals(emptyList<String>(), ids(q(search = "dev")))
        assertEquals(listOf("a"), ids(q(search = "ops")))

        dao.deleteItem("a")
        assertEquals(emptyList<String>(), ids(q(search = "rust")))
        assertNull(dao.ftsRowIdOf("a"))
    }

    @Test fun bodyIsSearchableAndSurvivesUpsert() = runBlocking {
        dao.upsertItem(item("a", title = "Plain"))
        dao.setFtsBody("a", "the quick brown fox jumps")
        assertEquals(listOf("a"), ids(q(search = "brown fox")))
        dao.upsertItem(item("a", title = "Plain renamed"))
        assertEquals(listOf("a"), ids(q(search = "quick")))
        dao.setFtsBody("a", "")
        assertEquals(emptyList<String>(), ids(q(search = "quick")))
    }

    @Test fun searchSyntaxIsNeutralized() = runBlocking {
        dao.upsertItem(item("a", title = "Hello world"))
        // would be an FTS syntax error if passed through
        for (s in listOf("\"", "hello AND", "(hello", "hello*:", "-hello", "NEAR(")) {
            page(q(search = s))
        }
        assertEquals(listOf("a"), ids(q(search = "\"hello\" -")))
    }

    @Test fun upsertPreservesFtsRowIdAndChildren() = runBlocking {
        dao.upsertItemWithTags(item("a"), listOf("x"))
        dao.upsertItem(item("b"))
        val rowA = dao.ftsRowIdOf("a")!!
        val rowB = dao.ftsRowIdOf("b")!!
        assertNotEquals(rowA, rowB)
        db.contentFileDao().upsert(ContentFileEntity("a", "c-a", ContentState.DOWNLOADED, bytes = 10))
        dao.upsertItem(item("a", title = "changed"))
        assertEquals(rowA, dao.ftsRowIdOf("a"))
        assertEquals(listOf("x"), dao.tagNames("a"))
        assertEquals(10L, db.contentFileDao().get("a")!!.bytes)
    }

    @Test fun pagingOrderPerSort() = runBlocking {
        dao.upsertItem(item("old", savedAt = 100, words = 900))
        dao.upsertItem(item("mid", savedAt = 200, words = 100))
        dao.upsertItem(item("new", savedAt = 300, words = 500))
        dao.upsertItem(item("nowords", savedAt = 400, words = null))
        assertEquals(listOf("nowords", "new", "mid", "old"), ids(q(sort = SortOrder.NEWEST)))
        assertEquals(listOf("old", "mid", "new", "nowords"), ids(q(sort = SortOrder.OLDEST)))
        assertEquals(listOf("mid", "new", "old", "nowords"), ids(q(sort = SortOrder.SHORTEST)))
        assertEquals(listOf("old", "new", "mid", "nowords"), ids(q(sort = SortOrder.LONGEST)))
        // sorting also applies to search results
        assertEquals(listOf("old", "new", "mid", "nowords"), ids(q(search = "title", sort = SortOrder.LONGEST)))
    }

    @Test fun tabsAndTagFilters() = runBlocking {
        dao.upsertItemWithTags(item("u1", savedAt = 1), listOf("Read Later"))
        dao.upsertItemWithTags(item("u2", savedAt = 2, favorite = true), listOf("other"))
        dao.upsertItemWithTags(item("a1", savedAt = 3, status = ItemStatus.ARCHIVED, archivedAt = 9), listOf("read later"))
        dao.upsertItem(item("a2", savedAt = 4, status = ItemStatus.ARCHIVED, favorite = true, archivedAt = 9))
        assertEquals(listOf("u2", "u1"), ids(q(LibraryTab.MY_LIST)))
        assertEquals(listOf("a2", "a1"), ids(q(LibraryTab.ARCHIVE)))
        assertEquals(listOf("a2", "u2"), ids(q(LibraryTab.FAVORITES)))
        // tag view ignores the tab, matches case-insensitively, any status
        assertEquals(listOf("a1", "u1"), ids(q(LibraryTab.FAVORITES, tag = "READ LATER")))
        assertEquals(listOf("a1"), ids(q(tag = "read later", search = "title")).filter { it == "a1" })
        assertEquals(listOf("u1"), ids(q(LibraryTab.MY_LIST, search = "title")).filter { it == "u1" })
        assertEquals(emptyList<String>(), ids(q(LibraryTab.ARCHIVE, search = "u1")))

        val counts = dao.observeCounts().first()
        assertEquals(Triple(2, 2, 2), Triple(counts.unread, counts.archived, counts.favorites))
        assertEquals(
            listOf("other" to 1, "Read Later" to 2).sortedBy { it.first.lowercase() },
            dao.observeTagCounts().first().map { it.name to it.count },
        )
    }

    @Test fun rowProjectionHasTagsAndOfflineState() = runBlocking {
        dao.upsertItemWithTags(item("a"), listOf("b-tag", "A-tag"))
        dao.upsertItem(item("nocontent", contentId = null, savedAt = 5))
        db.contentFileDao().upsert(ContentFileEntity("a", "c-a", ContentState.DOWNLOADED, thumbPath = "/t/a.webp"))
        val a = page(q()).first { it.id == "a" }.toSummary()
        assertEquals(listOf("A-tag", "b-tag"), a.tags)
        assertEquals(OfflineState.DOWNLOADED, a.offline)
        assertEquals("/t/a.webp", a.thumbnailPath)
        assertEquals(OfflineState.NONE, page(q()).first { it.id == "nocontent" }.toSummary().offline)
        // stale content id => AVAILABLE_REMOTE
        dao.upsertItem(item("a", contentId = "c-a2"))
        assertEquals(OfflineState.AVAILABLE_REMOTE, dao.observeItem("a").first()!!.toItem().offline)
        assertNull(dao.observeItem("zzz").first())
    }

    @Test fun cascadeDeletes() = runBlocking {
        dao.upsertItemWithTags(item("a"), listOf("x"))
        db.contentFileDao().upsert(ContentFileEntity("a", "c-a", ContentState.QUEUED))
        dao.deleteItem("a")
        assertEquals(emptyList<String>(), dao.tagNames("a"))
        assertNull(db.contentFileDao().get("a"))
        assertEquals(emptyList<Any>(), dao.observeTagCounts().first())
    }

    @Test fun renameAndDeleteTag() = runBlocking {
        dao.upsertItemWithTags(item("a"), listOf("old", "new"))
        dao.upsertItemWithTags(item("b"), listOf("Old"))
        dao.renameTag("old", "New")
        assertEquals(listOf("new"), dao.tagNames("a").map { it.lowercase() })
        assertEquals(listOf("New"), dao.tagNames("b"))
        assertEquals(listOf("b", "a").toSet(), ids(q(tag = "new")).toSet())
        assertEquals(listOf("a", "b").toSet(), ids(q(search = "new", tag = "new")).toSet())
        dao.deleteTag("new")
        assertEquals(emptyList<String>(), dao.tagNames("a") + dao.tagNames("b"))
    }

    @Test fun resyncMarksDeleteOnlyStaleWithoutPendingOps() = runBlocking {
        dao.upsertItem(item("keep")); dao.upsertItem(item("gone")); dao.upsertItem(item("pending"))
        db.pendingOpDao().enqueue(op("o1", "pending", "item.tag"))
        dao.markAllForResync()
        dao.upsertItem(item("keep")) // re-pulled: resetMark=0
        assertEquals(listOf("gone").toSet(), dao.deleteStaleMarkedItems().toSet())
        assertEquals(setOf("keep", "pending"), ids(q()).toSet())
    }

    @Test fun wipeAllEmptiesEverything() = runBlocking {
        dao.upsertItemWithTags(item("a"), listOf("x"))
        db.pendingOpDao().enqueue(op("o1", "a", "item.tag"))
        db.syncStateDao().update { it.copy(cursor = 5) }
        db.contentFileDao().upsert(ContentFileEntity("a", "c-a", ContentState.DOWNLOADED))
        db.maintenanceDao().wipeAll()
        assertEquals(emptyList<String>(), ids(q()) + ids(q(search = "title")))
        assertEquals(0, db.pendingOpDao().count())
        assertEquals(0L, db.syncStateDao().get().cursor)
        assertEquals(emptyList<Any>(), db.contentFileDao().all())
    }

    @Test fun transactionRollsBackAcrossDaos() = runBlocking {
        runCatching {
            db.withWriteTransaction {
                dao.upsertItem(item("a"))
                db.pendingOpDao().enqueue(op("o1", "a", "item.add"))
                error("boom")
            }
        }
        assertNull(dao.getItem("a"))
        assertEquals(0, db.pendingOpDao().count())
        db.withWriteTransaction {
            dao.upsertItem(item("a"))
            db.pendingOpDao().enqueue(op("o2", "a", "item.add"))
        }
        assertEquals(1, db.pendingOpDao().count())
    }
}
