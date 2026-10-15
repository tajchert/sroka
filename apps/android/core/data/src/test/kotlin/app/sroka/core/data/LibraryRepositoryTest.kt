package app.sroka.core.data

import app.sroka.core.data.ops.WireOp
import app.sroka.core.data.repository.TagRepositoryImpl
import app.sroka.core.domain.SaveSource
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.ParseStatus
import app.sroka.core.model.SaveResult
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

internal class LibraryRepositoryTest : DataTestBase() {

    @Test fun saveCreatesPendingItemAndAddOp() = runBlocking {
        val r = library.save("https://Example.com/post?utm_source=x", "Hi", listOf(" travel ", "Travel", "food"), SaveSource.MANUAL) as SaveResult.Saved
        assertFalse(r.alreadySaved)
        val item = library.observeItem(r.itemId).first()!!
        assertEquals("https://example.com/post", item.canonicalUrl)
        assertEquals(ParseStatus.PENDING, item.parseStatus)
        assertEquals(listOf("food", "travel"), item.tags)
        val op = pendingOps().single() as WireOp.Add
        assertEquals(r.itemId, op.itemId)
        assertEquals(listOf("travel", "food"), op.tags)
        assertEquals("web", op.source)
        assertTrue(pendingOpDao.batch(10).single().payload.contains(""""onDuplicate":"readd""""))
        assertEquals(1, syncController.syncRequests)
    }

    @Test fun saveSameCanonicalUrlReAddsExistingItem() = runBlocking {
        val first = library.save("https://example.com/a") as SaveResult.Saved
        library.setStatus(first.itemId, ItemStatus.ARCHIVED)
        now += 1000
        val second = library.save("https://example.com/a#frag", tags = listOf("x")) as SaveResult.Saved
        assertEquals(first.itemId, second.itemId)
        assertTrue(second.alreadySaved)
        val item = library.observeItem(first.itemId).first()!!
        assertEquals(ItemStatus.UNREAD, item.status)
        assertEquals(now, item.savedAt)
        assertEquals(listOf("x"), item.tags)
        assertEquals(listOf(WireOp.ADD, WireOp.SET_STATUS, WireOp.ADD), pendingOps().map { it.type })
    }

    @Test fun invalidUrl() = runBlocking {
        assertEquals(SaveResult.InvalidUrl, library.save("not a url"))
        assertEquals(0, pendingOpDao.count())
    }

    @Test fun coalescesProgressStatusFavoriteAndTitle() = runBlocking {
        itemDao.upsertItem(entity("a"))
        repeat(3) { library.setProgress("a", it / 10f, it) }
        library.setFavorite("a", true)
        library.setFavorite("a", false)
        library.setStatus("a", ItemStatus.ARCHIVED)
        library.setStatus("a", ItemStatus.UNREAD)
        library.setTitle("a", "x")
        library.setTitle("a", " ")
        val ops = pendingOps()
        assertEquals(4, ops.size)
        assertEquals(0.2f, (ops.single { it is WireOp.SetProgress } as WireOp.SetProgress).progress)
        assertEquals(false, (ops.single { it is WireOp.SetFavorite } as WireOp.SetFavorite).value)
        assertEquals(ItemStatus.UNREAD, (ops.single { it is WireOp.SetStatus } as WireOp.SetStatus).status)
        assertNull((ops.single { it is WireOp.SetTitle } as WireOp.SetTitle).title)
    }

    @Test fun tagOpsAreNeverCoalesced() = runBlocking {
        itemDao.upsertItemWithTags(entity("a"), listOf("Old", "keep"))
        library.setTags("a", listOf("keep", "New"))
        library.setTags("a", listOf("keep"))
        val ops = pendingOps().map { it as WireOp.Tag }
        assertEquals(listOf("Old" to false, "New" to true, "New" to false), ops.map { it.tag to it.present })
        assertEquals(listOf("keep"), itemDao.tagNames("a"))
    }

    @Test fun archiveSetsArchivedAtAndMissingItemIsNoOp() = runBlocking {
        itemDao.upsertItem(entity("a"))
        library.setStatus("a", ItemStatus.ARCHIVED)
        assertEquals(now, itemDao.getItem("a")!!.archivedAt)
        library.setFavorite("missing", true)
        assertEquals(1, pendingOpDao.count())
    }

    @Test fun deleteRemovesRowAndFiles() = runBlocking {
        itemDao.upsertItem(entity("a"))
        paths.articleDir("a").mkdirs()
        File(paths.articleDir("a"), "article.html").writeText("x")
        library.delete("a")
        assertNull(itemDao.getItem("a"))
        assertFalse(paths.articleDir("a").exists())
        assertEquals(WireOp.DELETE, pendingOps().single().type)
    }

    @Test fun tagRenameAndDelete() = runBlocking {
        val tags = TagRepositoryImpl(itemDao, writer, syncController)
        itemDao.upsertItemWithTags(entity("a"), listOf("ml"))
        itemDao.upsertItemWithTags(entity("b"), listOf("ML", "x"))
        assertEquals(app.sroka.core.domain.TagEditResult.InvalidName, tags.rename("ml", "  "))
        tags.rename("ml", "machine-learning")
        assertEquals(listOf("machine-learning"), itemDao.tagNames("a"))
        assertEquals(listOf("machine-learning", "x"), itemDao.tagNames("b"))
        tags.delete("x")
        assertEquals(listOf("machine-learning"), itemDao.tagNames("b"))
        assertEquals(listOf(WireOp.TAG_RENAME, WireOp.TAG_DELETE), pendingOps().map { it.type })
        assertNull(pendingOpDao.batch(10).first().itemId)
    }
}
