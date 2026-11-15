package app.sroka.core.database

import androidx.room3.withWriteTransaction
import app.sroka.core.database.entity.ContentFileEntity
import app.sroka.core.database.entity.ContentState
import app.sroka.core.model.ItemKind
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.OfflineState
import app.sroka.core.model.ParseStatus
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

    @Test fun nextUnreadSkipsTheExcludedItem() = runBlocking {
        dao.upsertItem(item("old", savedAt = 100))
        dao.upsertItem(item("new", savedAt = 300))
        assertEquals("new", dao.observeNextUnread(null).first()?.id)
        assertEquals("old", dao.observeNextUnread("new").first()?.id)
        assertEquals("new", dao.observeNextUnread("old").first()?.id)
        assertEquals("new", dao.observeNextUnread("missing").first()?.id)
    }

    @Test fun nextReadableSkipsPendingAndFailedItems() = runBlocking {
        dao.upsertItem(item("open", savedAt = 50))
        dao.upsertItem(item("older", savedAt = 100))
        dao.upsertItem(item("pending", savedAt = 300).copy(parseStatus = ParseStatus.PENDING))
        dao.upsertItem(item("failed", savedAt = 200).copy(parseStatus = ParseStatus.FAILED))
        dao.upsertItem(item("done", savedAt = 400, status = ItemStatus.ARCHIVED))
        assertEquals("pending", dao.observeNextUnread("open").first()?.id)
        assertEquals("older", dao.observeNextReadable("open").first()?.id)
        dao.upsertItem(item("partial", savedAt = 150).copy(parseStatus = ParseStatus.PARTIAL))
        assertEquals("partial", dao.observeNextReadable("open").first()?.id)
        dao.upsertItem(item("pdf", savedAt = 250).copy(parseStatus = ParseStatus.PENDING, kind = ItemKind.PDF))
        assertEquals("pdf", dao.observeNextReadable("open").first()?.id)
    }

    @Test fun nextUnreadIsNullWhenOnlyTheExcludedItemIsUnread() = runBlocking {
        dao.upsertItem(item("only", savedAt = 100))
        assertNull(dao.observeNextUnread("only").first())
    }

    @Test fun tabsAndTagFilters() = runBlocking {
        dao.upsertItemWithTags(item("u1", savedAt = 1), listOf("Read Later"))
        dao.upsertItemWithTags(item("u2", savedAt = 2, favorite = true), listOf("other"))
        dao.upsertItemWithTags(item("a1", savedAt = 3, status = ItemStatus.ARCHIVED, archivedAt = 9), listOf("read later"))
        dao.upsertItem(item("a2", savedAt = 4, status = ItemStatus.ARCHIVED, favorite = true, archivedAt = 9))
        assertEquals(listOf("u2", "u1"), ids(q(LibraryTab.MY_LIST)))
        assertEquals(listOf("a2", "a1"), ids(q(LibraryTab.ARCHIVE)))
        assertEquals(listOf("a2", "u2"), ids(q(LibraryTab.FAVORITES)))
        // a tag page (no tab) matches case-insensitively, any status
        assertEquals(listOf("a1", "u1"), ids(q(tab = null, tag = "READ LATER")))
        assertEquals(listOf("a1"), ids(q(tab = null, tag = "read later", search = "title")).filter { it == "a1" })
        // with a tab the tag narrows that tab
        assertEquals(listOf("u1"), ids(q(LibraryTab.MY_LIST, tag = "read later")))
        assertEquals(emptyList<String>(), ids(q(LibraryTab.FAVORITES, tag = "READ LATER")))
        assertEquals(listOf("u1"), ids(q(LibraryTab.MY_LIST, search = "title")).filter { it == "u1" })
        assertEquals(emptyList<String>(), ids(q(LibraryTab.ARCHIVE, search = "u1")))

        val counts = dao.observeCounts().first()
        assertEquals(Triple(2, 2, 2), Triple(counts.unread, counts.archived, counts.favorites))
        assertEquals(
            listOf("other" to 1, "Read Later" to 2).sortedBy { it.first.lowercase() },
            dao.observeTagCounts().first().map { it.name to it.count },
        )
    }

    @Test fun favoritesAndReadingTimeFiltersCombineWithTabTagSortAndSearch() = runBlocking {
        // words / 200 = reading minutes: 400 -> 2, 1800 -> 9, 2000 -> 10, null -> unknown
        dao.upsertItemWithTags(item("short", savedAt = 1, words = 400, favorite = true), listOf("news"))
        dao.upsertItemWithTags(item("nine", savedAt = 2, words = 1800), listOf("news"))
        dao.upsertItemWithTags(item("ten", savedAt = 3, words = 2000, favorite = true), listOf("news"))
        dao.upsertItem(item("unknown", savedAt = 4, words = null, favorite = true))
        dao.upsertItemWithTags(
            item("archived", savedAt = 5, words = 400, favorite = true, status = ItemStatus.ARCHIVED, archivedAt = 9),
            listOf("news"),
        )

        assertEquals(listOf("unknown", "ten", "short"), ids(q(favoritesOnly = true)))
        assertEquals(listOf("nine", "short"), ids(q(maxReadingMinutes = 9)))
        assertEquals(listOf("short"), ids(q(favoritesOnly = true, maxReadingMinutes = 9)))
        assertEquals(listOf("ten", "short"), ids(q(favoritesOnly = true, tag = "NEWS")))
        assertEquals(listOf("short"), ids(q(favoritesOnly = true, maxReadingMinutes = 9, tag = "news")))
        assertEquals(listOf("archived"), ids(q(LibraryTab.ARCHIVE, favoritesOnly = true, maxReadingMinutes = 9, tag = "news")))
        // sort still applies; unknown length sorts last
        assertEquals(listOf("short", "ten", "unknown"), ids(q(favoritesOnly = true, sort = SortOrder.SHORTEST)))
        assertEquals(listOf("nine", "short"), ids(q(maxReadingMinutes = 9, sort = SortOrder.LONGEST)))
        assertEquals(listOf("short", "nine"), ids(q(maxReadingMinutes = 9, sort = SortOrder.OLDEST)))
        // with search
        assertEquals(listOf("ten", "short"), ids(q(favoritesOnly = true, search = "title", tag = "news")))
        assertEquals(listOf("short"), ids(q(search = "short", maxReadingMinutes = 9)))
        assertEquals(emptyList<String>(), ids(q(search = "ten", maxReadingMinutes = 9)))
        // Favorites tab + favoritesOnly is just Favorites
        assertEquals(ids(q(LibraryTab.FAVORITES)), ids(q(LibraryTab.FAVORITES, favoritesOnly = true)))
        // no tab: everything live
        assertEquals(5, ids(q(tab = null)).size)
    }

    @Test fun continueReadingIsUnreadInProgressNewestReadFirst() = runBlocking {
        dao.upsertItem(item("fresh", progress = 0.01f, lastReadAt = 900))
        dao.upsertItem(item("a", progress = 0.05f, lastReadAt = 100))
        dao.upsertItem(item("b", progress = 0.5f, lastReadAt = 300))
        dao.upsertItem(item("c", progress = 0.95f, lastReadAt = 200))
        dao.upsertItem(item("done", progress = 0.99f, lastReadAt = 950))
        dao.upsertItem(item("arch", progress = 0.5f, lastReadAt = 999, status = ItemStatus.ARCHIVED, archivedAt = 1))
        assertEquals(listOf("b", "c", "a"), dao.observeContinueReading(10).first().map { it.id })
        assertEquals(listOf("b", "c"), dao.observeContinueReading(2).first().map { it.id })
    }

    @Test fun rowProjectionHasParseError() = runBlocking {
        dao.upsertItem(item("p").copy(parseStatus = ParseStatus.PARTIAL, parseError = "paywalled"))
        assertEquals("paywalled", page(q()).single().toSummary().parseError)
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

    @Test fun statusOnlyUpsertKeepsBodyAndTitleChangeReindexes() = runBlocking {
        dao.upsertItemWithTags(item("a", title = "Plain", siteName = "Blog"), listOf("dev"))
        dao.setFtsBody("a", "the quick brown fox jumps")
        // server echo of a status change: indexed metadata identical
        dao.upsertItemWithTags(item("a", title = "Plain", siteName = "Blog", status = ItemStatus.ARCHIVED, archivedAt = 5), listOf("dev"))
        assertEquals(listOf("a"), ids(q(LibraryTab.ARCHIVE, search = "brown fox")))
        assertEquals(listOf("dev"), dao.tagNames("a"))
        // a title change is re-indexed and the body is still there
        dao.upsertItemWithTags(item("a", title = "Renamed", siteName = "Blog", status = ItemStatus.ARCHIVED, archivedAt = 5), listOf("dev"))
        assertEquals(listOf("a"), ids(q(LibraryTab.ARCHIVE, search = "renamed")))
        assertEquals(emptyList<String>(), ids(q(LibraryTab.ARCHIVE, search = "plain")))
        assertEquals(listOf("a"), ids(q(LibraryTab.ARCHIVE, search = "quick")))
        // tag change is re-indexed
        dao.upsertItemWithTags(item("a", title = "Renamed", siteName = "Blog", status = ItemStatus.ARCHIVED, archivedAt = 5), listOf("ops"))
        assertEquals(listOf("a"), ids(q(LibraryTab.ARCHIVE, search = "ops")))
        assertEquals(emptyList<String>(), ids(q(LibraryTab.ARCHIVE, search = "dev")))
        assertEquals(listOf("a"), ids(q(LibraryTab.ARCHIVE, search = "quick")))
    }

    @Test fun rekeyItemMovesRowTagsAndFts() = runBlocking {
        dao.upsertItemWithTags(item("x", title = "Kotlin article"), listOf("t1"))
        dao.upsertItem(item("other"))
        db.contentFileDao().upsert(ContentFileEntity("x", "c-x", ContentState.QUEUED))
        val rowId = dao.ftsRowIdOf("x")
        dao.rekeyItem("x", "y")
        assertNull(dao.getItem("x"))
        assertEquals(rowId, dao.ftsRowIdOf("y"))
        assertEquals(listOf("t1"), dao.tagNames("y"))
        assertNull(db.contentFileDao().get("x"))
        assertEquals(listOf("y"), ids(q(search = "kotlin")))
        // a later pull of the canonical row overwrites it in place
        dao.upsertItemWithTags(item("y", title = "Server title"), listOf("t1"))
        assertEquals(listOf("y"), ids(q(search = "server")))
        assertEquals(rowId, dao.ftsRowIdOf("y"))
    }

    @Test fun largeIdListsAreChunked() = runBlocking {
        dao.upsertItem(item("a"))
        val ids = (1..2500).map { "id$it" } + "a"
        assertEquals(listOf("a"), dao.existingIds(ids))
        dao.deleteTagRowsById(ids)
        val ops = db.pendingOpDao()
        ops.enqueue(op("o1", "a", "item.tag"))
        assertEquals(1, ops.forItems(ids).size)
        ops.markAttempted((1..2500).map { "o$it" }, "x")
        ops.deleteByOpIds((1..2500).map { "o$it" })
        assertEquals(0, ops.count())
    }
}
