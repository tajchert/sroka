package app.sroka.core.data

import app.sroka.core.data.ops.WireOp
import app.sroka.core.data.ops.toEntity
import app.sroka.core.data.sync.SyncOutcome
import app.sroka.core.database.entity.ContentFileEntity
import app.sroka.core.database.entity.ContentState
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.SaveResult
import app.sroka.core.model.SyncErrorKind
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.RecordedRequest

internal class SyncEngineTest : DataTestBase() {

    @Test fun pushAppliedRemovesOpsThenPulls() = runBlocking {
        val id = (library.save("https://example.com/a") as SaveResult.Saved).itemId
        val opId = pendingOpDao.batch(1).single().opId
        enqueueJson("""{"applied":["$opId"],"rejected":[],"aliases":{},"cursor":5}""")
        enqueueJson(pullJson(5, listOf(itemJson(id, 5, title = "Parsed"))))
        assertEquals(SyncOutcome.Success(1), engine.sync())

        val push = takeRequest()
        assertEquals("/v1/sync/push", push.url.encodedPath)
        val body = push.body!!.utf8()
        assertTrue(body, body.startsWith("""{"deviceId":"${sessionStore.deviceId()}","ops":[{"opId":"$opId","type":"item.add","itemId":"$id""""))
        assertEquals("0", takeRequest().url.queryParameter("cursor"))
        assertEquals(0, pendingOpDao.count())
        assertEquals("Parsed", itemDao.getItem(id)!!.title)
        assertEquals(5, syncStateDao.get().cursor)
        assertEquals(now, syncStateDao.get().lastSuccessAt)
    }

    @Test fun rejectedItemDeletedRemovesLocalItem() = runBlocking {
        itemDao.upsertItem(entity("a"))
        library.setFavorite("a", true)
        library.setStatus("a", ItemStatus.ARCHIVED)
        val ops = pendingOpDao.batch(10).map { it.opId }
        enqueueJson("""{"applied":[],"rejected":[{"opId":"${ops[0]}","reason":"item_deleted"},{"opId":"${ops[1]}","reason":"item_deleted"}],"aliases":{},"cursor":1}""")
        enqueueJson(pullJson(1))
        engine.sync()
        assertNull(itemDao.getItem("a"))
        assertEquals(0, pendingOpDao.count())
    }

    @Test fun otherRejectsOnlyDropTheOp() = runBlocking {
        itemDao.upsertItem(entity("a"))
        library.setFavorite("a", true)
        val op = pendingOpDao.batch(1).single().opId
        enqueueJson("""{"applied":[],"rejected":[{"opId":"$op","reason":"unknown_item"}],"aliases":{},"cursor":1}""")
        enqueueJson(pullJson(1))
        engine.sync()
        assertNotNull(itemDao.getItem("a"))
        assertEquals(0, pendingOpDao.count())
    }

    @Test fun aliasesRewriteQueuedOpsAndDropClientRow() = runBlocking {
        val client = (library.save("https://example.com/dup") as SaveResult.Saved).itemId
        val addOp = pendingOpDao.batch(1).single().opId
        // Server answers the push of the add; meanwhile (simulated) a later op is queued on the client id.
        val later = WireOp.SetFavorite("later", client, now, true)
        pendingOpDao.enqueue(app.sroka.core.database.entity.PendingOpEntity(opId = later.opId, itemId = client, type = later.type, payload = later.payload(), createdAt = now))
        server.enqueue(
            MockResponse.Builder().code(200).addHeader("Content-Type", "application/json")
                .body("""{"applied":["$addOp"],"rejected":[],"aliases":{"$client":"server-1"},"cursor":3}""").build(),
        )
        // Second push batch: the rewritten favorite op; fail it on network to inspect the queue afterwards.
        server.enqueue(MockResponse.Builder().code(503).build())
        engine.sync()
        // The add + favorite were in the same first batch; favorite was not acknowledged -> rewritten.
        assertNull(itemDao.getItem(client))
        val queued = pendingOpDao.batch(10).single()
        assertEquals("server-1", queued.itemId)
        assertTrue(queued.payload.contains(""""itemId":"server-1""""))
    }

    @Test fun rejectedAddRemovesLocalOnlyOrphanButKeepsServerRows() = runBlocking {
        val orphan = (library.save("https://example.com/o") as SaveResult.Saved).itemId
        library.setFavorite(orphan, true)
        itemDao.upsertItem(entity("known")) // serverSeq = 1: exists on the server
        val ops = pendingOpDao.batch(10)
        val add = ops.first { it.type == WireOp.ADD }.opId
        enqueueJson("""{"applied":[],"rejected":[{"opId":"$add","reason":"invalid_op"}],"aliases":{},"cursor":1}""")
        enqueueJson(pullJson(1))
        engine.sync()
        assertNull(itemDao.getItem(orphan))
        assertEquals(0, pendingOpDao.count())
        assertNotNull(itemDao.getItem("known"))
    }

    @Test fun rejectedAddOfServerKnownItemKeepsRow() = runBlocking {
        itemDao.upsertItem(entity("known"))
        val add = WireOp.Add("op-add", "known", now, "https://example.com/known", null, emptyList(), "web", now)
        pendingOpDao.enqueue(add.toEntity(now))
        enqueueJson("""{"applied":[],"rejected":[{"opId":"op-add","reason":"invalid_op"}],"aliases":{},"cursor":1}""")
        enqueueJson(pullJson(1))
        engine.sync()
        assertNotNull(itemDao.getItem("known"))
    }

    @Test fun reSaveAfterRemoteDeleteRekeysTheAddOnItemDeleted() = runBlocking {
        itemDao.upsertItem(entity("y")) // known to the server; deleted there by another device
        val saved = library.save("https://example.com/y", tags = listOf("t")) as SaveResult.Saved
        assertEquals("y", saved.itemId)
        library.setFavorite("y", true)
        val ops = pendingOpDao.batch(10)
        val addId = ops[0].opId
        val favId = ops[1].opId
        enqueueJson("""{"applied":[],"rejected":[{"opId":"$addId","reason":"item_deleted"},{"opId":"$favId","reason":"item_deleted"}],"aliases":{},"cursor":1}""")
        server.enqueue(MockResponse.Builder().code(503).build()) // stop after the re-keyed push
        engine.sync()

        assertNull(itemDao.getItem("y"))
        val queued = pendingOpDao.batch(10)
        assertEquals(listOf(WireOp.ADD, WireOp.SET_FAVORITE), queued.map { it.type })
        val newId = queued[0].itemId!!
        assertTrue(newId != "y")
        assertEquals(newId, queued[1].itemId)
        assertTrue(queued[0].opId != addId) // the server already acknowledged the old op id
        assertTrue(queued[0].payload.contains(""""opId":"${queued[0].opId}""""))
        assertTrue(queued[0].payload.contains(""""itemId":"$newId""""))
        val local = itemDao.getItem(newId)!!
        assertTrue(local.isFavorite)
        assertEquals(listOf("t"), itemDao.tagNames(newId))
        // the re-keyed ops were actually sent on the next push
        takeRequest()
        val second = takeRequest().body!!.utf8()
        assertTrue(second, second.contains(""""itemId":"$newId""""))
    }

    @Test fun reSaveWhileTombstonePullsInRekeysThePendingAdd() = runBlocking {
        itemDao.upsertItem(entity("y"))
        serve { request ->
            if (request.url.encodedPath == "/v1/sync/pull") {
                // The user re-saves the URL while the page carrying y's tombstone is in flight.
                runBlocking { library.save("https://example.com/y") }
                json(pullJson(2, deletedItems = listOf("y")))
            } else {
                json("""{"applied":[],"rejected":[],"aliases":{},"cursor":2}""")
            }
        }
        assertTrue(engine.sync() is SyncOutcome.Success)
        assertNull(itemDao.getItem("y"))
        val queued = pendingOpDao.batch(10).single()
        assertEquals(WireOp.ADD, queued.type)
        val newId = queued.itemId!!
        assertTrue(newId != "y")
        assertNotNull(itemDao.getItem(newId))
        assertTrue(queued.payload.contains(""""itemId":"$newId""""))
    }

    @Test fun aliasKeepsSavedItemWhenThePullFails() = runBlocking {
        val client = (library.save("https://example.com/dup2") as SaveResult.Saved).itemId
        val addOp = pendingOpDao.batch(1).single().opId
        enqueueJson("""{"applied":["$addOp"],"rejected":[],"aliases":{"$client":"server-9"},"cursor":3}""")
        server.enqueue(MockResponse.Builder().code(503).build()) // pull fails
        assertTrue(engine.sync() is SyncOutcome.Failure)
        assertNull(itemDao.getItem(client))
        val kept = itemDao.getItem("server-9")
        assertNotNull(kept) // the user's save did not vanish
        assertEquals("https://example.com/dup2", kept!!.url)
        // writes made meanwhile on the displayed item are not dropped
        library.setFavorite("server-9", true)
        assertEquals(1, pendingOpDao.count())
    }

    @Test fun pendingTagRenameSurvivesAPageThatCarriesOnlyTags() = runBlocking {
        itemDao.upsertItemWithTags(entity("a"), listOf("ml"))
        serve { request ->
            if (request.url.encodedPath == "/v1/sync/pull") {
                runBlocking {
                    val op = WireOp.TagRename(writer.newOpId(now), now, "ml", "machine-learning")
                    writer.write { listOf(op) }
                }
                // page: only a tags row, no items
                json(pullJson(5, tags = """{"id":"t1","name":"ml","seq":5}"""))
            } else {
                json("""{"applied":[],"rejected":[],"aliases":{},"cursor":5}""")
            }
        }
        // The rename is queued during the pull, so it is re-applied on top of the page's tag row.
        engine.sync()
        assertEquals(listOf("machine-learning"), itemDao.tagNames("a"))
        assertTrue(itemDao.allTagRows().none { it.nameKey == "ml" })
    }

    @Test fun pullFromZeroIsFullAndNeverGets410AfterTheHorizon() = runBlocking {
        val horizon = 100L
        syncStateDao.update { it.copy(cursor = 5) }
        itemDao.upsertItem(entity("stale"))
        val seen = mutableListOf<String>()
        serve { request ->
            if (request.url.encodedPath != "/v1/sync/pull") {
                json("""{"applied":[],"rejected":[],"aliases":{},"cursor":0}""")
            } else {
                val cursor = request.url.queryParameter("cursor")!!.toLong()
                val full = request.url.queryParameter("full") == "1"
                seen += "$cursor/$full"
                when {
                    // the server's rule: only an incremental cursor below the horizon is refused
                    !full && cursor in 1 until horizon -> json("""{"error":"resync_required"}""", 410)
                    cursor == 0L -> json(pullJson(50, listOf(itemJson("a", 50)), hasMore = true))
                    else -> json(pullJson(120, listOf(itemJson("b", 120)), hasMore = false))
                }
            }
        }
        assertEquals(SyncOutcome.Success(2), engine.sync())
        assertEquals(listOf("5/false", "0/true", "50/true"), seen)
        assertEquals(120, syncStateDao.get().cursor)
        assertFalse(syncStateDao.get().fullResync)
        assertNull(itemDao.getItem("stale")) // did not come back in the full pass
        assertNotNull(itemDao.getItem("a"))

        // a later incremental pull is not "full"
        seen.clear()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                seen += request.url.queryParameter("full").toString()
                return json(pullJson(121))
            }
        }
        engine.sync()
        assertEquals(listOf("null"), seen)
    }

    @Test fun firstSyncFromZeroUsesFullPass() = runBlocking {
        val seen = mutableListOf<String>()
        serve { request ->
            val cursor = request.url.queryParameter("cursor")!!.toLong()
            seen += "$cursor/${request.url.queryParameter("full")}"
            if (cursor == 0L) json(pullJson(10, listOf(itemJson("a", 10)), hasMore = true)) else json(pullJson(20, listOf(itemJson("b", 20))))
        }
        assertEquals(SyncOutcome.Success(2), engine.sync())
        assertEquals(listOf("0/1", "10/1"), seen)
        assertFalse(syncStateDao.get().fullResync)
    }

    @Test fun unsafeServerIdsNeverReachTheDiskOrRoom() = runBlocking {
        val sibling = tmp.newFile("files/sibling.txt").also { it.writeText("keep") }
        itemDao.upsertItem(entity("a"))
        serve { json(pullJson(5, listOf(itemJson("../datastore", 5), itemJson("b", 5)), deletedItems = listOf("..", "../x", "a"))) }
        engine.sync()
        assertTrue(sibling.exists())
        assertNull(itemDao.getItem("../datastore"))
        assertNotNull(itemDao.getItem("b"))
        assertNull(itemDao.getItem("a"))
    }

    @Test fun pullPagesAdvanceCursorPerPageAtomically() = runBlocking {
        enqueueJson(pullJson(10, listOf(itemJson("a", 10, tags = listOf("x"))), hasMore = true, tags = """{"id":"t1","name":"x","seq":10}"""))
        enqueueJson(pullJson(20, listOf(itemJson("b", 20)), hasMore = true))
        server.enqueue(MockResponse.Builder().code(500).build())
        assertEquals(SyncOutcome.Failure(SyncErrorKind.SERVER), engine.sync())
        assertEquals(20, syncStateDao.get().cursor)
        assertEquals(listOf("x"), itemDao.tagNames("a"))
        assertNotNull(itemDao.getItem("b"))
        assertEquals("SERVER", syncStateDao.get().lastError)
        takeRequest()
        assertEquals("10", takeRequest().url.queryParameter("cursor"))
        assertEquals("20", takeRequest().url.queryParameter("cursor"))

        enqueueJson(pullJson(30, listOf(itemJson("c", 30)), deletedItems = listOf("a")))
        assertTrue(engine.sync() is SyncOutcome.Success)
        assertNull(itemDao.getItem("a"))
        assertEquals(30, syncStateDao.get().cursor)
    }

    @Test fun rebaseKeepsUnpushedLocalEdits() = runBlocking {
        itemDao.upsertItem(entity("a"))
        // Local edits made while the (older) server page is in flight stay queued and win locally.
        serve { request ->
            if (request.url.encodedPath == "/v1/sync/pull") {
                runBlocking {
                    library.setStatus("a", ItemStatus.ARCHIVED)
                    library.setFavorite("a", true)
                    library.setProgress("a", 0.7f, 3)
                    library.setTags("a", listOf("local"))
                }
                json(pullJson(1, listOf(itemJson("a", 1, status = "unread", favorite = false, progress = 0.1f, tags = listOf("srv")))))
            } else {
                json("""{"applied":[],"rejected":[],"aliases":{},"cursor":1}""")
            }
        }
        assertTrue(engine.sync() is SyncOutcome.Success)
        val item = itemDao.getItem("a")!!
        assertEquals(ItemStatus.ARCHIVED, item.status)
        assertTrue(item.isFavorite)
        assertEquals(0.7f, item.progress)
        assertEquals(3, item.progressAnchor)
        // The server added "srv"; our un-pushed "+local" is re-applied on top.
        assertEquals(listOf("local", "srv"), itemDao.tagNames("a"))
        assertEquals(1L, item.serverSeq)
        assertEquals(4, pendingOpDao.count())
    }

    @Test fun resync410DeletesVanishedItemsButKeepsPendingOnes() = runBlocking {
        syncStateDao.update { it.copy(cursor = 50) }
        itemDao.upsertItem(entity("kept"))
        itemDao.upsertItem(entity("gone"))
        itemDao.upsertItem(entity("local"))
        contentFileDao.upsert(ContentFileEntity("gone", "c-gone", ContentState.DOWNLOADED))
        paths.articleDir("gone").mkdirs()
        serve { request ->
            when (request.url.queryParameter("cursor")) {
                "50" -> json("""{"error":"resync_required"}""", 410)
                "0" -> {
                    runBlocking { library.setFavorite("local", true) }
                    json(pullJson(60, listOf(itemJson("kept", 60))))
                }
                else -> json("""{"applied":[],"rejected":[],"aliases":{},"cursor":60}""")
            }
        }
        assertEquals(SyncOutcome.Success(1), engine.sync())
        assertNotNull(itemDao.getItem("kept"))
        assertNotNull(itemDao.getItem("local"))
        assertNull(itemDao.getItem("gone"))
        assertFalse(paths.articleDir("gone").exists())
        assertFalse(syncStateDao.get().fullResync)
        assertEquals(60, syncStateDao.get().cursor)
        assertEquals(0, itemDao.getItem("kept")!!.resyncMark)
        assertEquals(0, itemDao.getItem("local")!!.resyncMark)
    }

    @Test fun unauthorizedMarksSessionExpiredAndKeepsData() = runBlocking {
        itemDao.upsertItem(entity("a"))
        library.setFavorite("a", true)
        enqueueJson("""{"error":"unauthorized"}""", code = 401)
        assertEquals(SyncOutcome.Failure(SyncErrorKind.AUTH), engine.sync())
        assertTrue(sessionStore.current()!!.expired)
        assertEquals(1, pendingOpDao.count())
        assertNotNull(itemDao.getItem("a"))
    }

    private fun json(body: String, code: Int = 200) =
        MockResponse.Builder().code(code).body(body).addHeader("Content-Type", "application/json").build()

    private fun serve(handler: (RecordedRequest) -> MockResponse) {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = handler(request)
        }
    }
}
