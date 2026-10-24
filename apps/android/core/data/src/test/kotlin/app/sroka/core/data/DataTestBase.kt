package app.sroka.core.data

import android.content.Context
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.room3.Room
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.core.app.ApplicationProvider
import app.sroka.core.common.Clock
import app.sroka.core.data.content.ContentPaths
import app.sroka.core.data.content.ContentStoreImpl
import app.sroka.core.data.content.DownloadCanceller
import app.sroka.core.data.ops.LocalOpApplier
import app.sroka.core.data.ops.OpWriter
import app.sroka.core.data.ops.WireOp
import app.sroka.core.data.repository.LibraryRepositoryImpl
import app.sroka.core.data.sync.SyncEngine
import app.sroka.core.database.SrokaDatabase
import app.sroka.core.database.entity.ItemEntity
import app.sroka.core.datastore.SessionStore
import app.sroka.core.datastore.TokenCipher
import app.sroka.core.model.ItemKind
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.ParseStatus
import app.sroka.core.network.NetworkConfig
import app.sroka.core.network.SessionProvider
import app.sroka.core.network.SrokaApiFactory
import app.sroka.core.testing.fake.FakeSyncController
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okio.Buffer
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** In-memory Room + MockWebServer + real api/session wiring, no Hilt. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
internal abstract class DataTestBase {
    @get:Rule
    val tmp = TemporaryFolder()

    protected val server = MockWebServer()
    protected lateinit var db: SrokaDatabase
    protected lateinit var paths: ContentPaths
    protected lateinit var sessionStore: SessionStore
    protected lateinit var engine: SyncEngine
    protected lateinit var contentStore: ContentStoreImpl
    protected lateinit var library: LibraryRepositoryImpl
    protected lateinit var writer: OpWriter
    protected val syncController = FakeSyncController()
    protected var cancelledDownloads = 0
    protected var now = 1_700_000_000_000L
    protected val clock = Clock { now }

    private val storeScope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    protected val itemDao get() = db.itemDao()
    protected val pendingOpDao get() = db.pendingOpDao()
    protected val syncStateDao get() = db.syncStateDao()
    protected val contentFileDao get() = db.contentFileDao()

    @Before
    fun setUpData() {
        server.start()
        val context = ApplicationProvider.getApplicationContext<Context>()
        db = Room.inMemoryDatabaseBuilder<SrokaDatabase>(context).setDriver(AndroidSQLiteDriver()).build()
        paths = ContentPaths(tmp.newFolder("files"), tmp.newFolder("cache"))
        val sessionFile = tmp.root.resolve("session.preferences_pb")
        sessionStore = SessionStore(PreferenceDataStoreFactory.create(scope = storeScope) { sessionFile }, PlainCipher)
        runBlocking { sessionStore.save("tok", "me@example.com") }
        val provider = object : SessionProvider {
            override suspend fun token() = sessionStore.token()
            override suspend fun deviceId() = "and_test"
            override suspend fun baseUrl() = server.url("/").toString().trimEnd('/')
        }
        val api = SrokaApiFactory.create(provider, NetworkConfig("Sroka-Android/test"))
        val applier = LocalOpApplier(db.itemDao())
        writer = OpWriter(db, applier, db.pendingOpDao(), clock)
        engine = SyncEngine(db, db.itemDao(), db.pendingOpDao(), db.syncStateDao(), api, sessionStore, applier, paths, clock, Dispatchers.IO)
        contentStore = ContentStoreImpl(db, db.itemDao(), db.contentFileDao(), api, sessionStore, paths, clock, Dispatchers.IO, DownloadCanceller { cancelledDownloads++ })
        library = LibraryRepositoryImpl(db.itemDao(), writer, syncController, paths, Dispatchers.IO)
    }

    @After
    fun tearDownData() {
        db.close()
        server.close()
        storeScope.cancel()
    }

    protected fun enqueueJson(body: String, code: Int = 200) {
        server.enqueue(MockResponse.Builder().code(code).body(body).addHeader("Content-Type", "application/json").build())
    }

    protected fun enqueueBytes(bytes: ByteArray, code: Int = 200) {
        server.enqueue(MockResponse.Builder().code(code).body(Buffer().write(bytes)).build())
    }

    protected fun takeRequest(): RecordedRequest = server.takeRequest()

    protected suspend fun pendingOps(): List<WireOp> = pendingOpDao.batch(1000).map { WireOp.parse(it.payload)!! }

    protected fun entity(
        id: String,
        title: String? = "Title $id",
        savedAt: Long = 1_000,
        status: ItemStatus = ItemStatus.UNREAD,
        favorite: Boolean = false,
        contentId: String? = "c-$id",
        archivedAt: Long? = null,
        leadImageKey: String? = null,
        kind: ItemKind = ItemKind.ARTICLE,
    ) = ItemEntity(
        id = id, url = "https://example.com/$id", canonicalUrl = "https://example.com/$id",
        title = title, excerpt = null, siteName = null, author = null, lang = null, leadImageKey = leadImageKey,
        wordCount = 500, readingMinutes = 3, contentId = contentId, contentPrivate = false,
        parseStatus = ParseStatus.OK, parseError = null, status = status, isFavorite = favorite, progress = 0f,
        progressAnchor = null, savedAt = savedAt, archivedAt = archivedAt, lastReadAt = null, source = "web", serverSeq = 1,
        kind = kind, fileName = if (kind == ItemKind.PDF) "$id.pdf" else null, fileSize = if (kind == ItemKind.PDF) 1234 else null,
    )

    /** Server item JSON (api.md §4.1). */
    protected fun itemJson(
        id: String,
        seq: Long,
        title: String = "Server $id",
        status: String = "unread",
        favorite: Boolean = false,
        progress: Float = 0f,
        tags: List<String> = emptyList(),
        contentId: String? = "c-$id",
        savedAt: Long = 1_000,
    ): String = """{"id":"$id","url":"https://example.com/$id","canonicalUrl":"https://example.com/$id",""" +
        """"title":"$title","parseStatus":"ok","status":"$status","isFavorite":$favorite,"progress":$progress,""" +
        """"savedAt":$savedAt,"tags":[${tags.joinToString(",") { "\"$it\"" }}],"seq":$seq""" +
        (if (contentId != null) ""","contentId":"$contentId"""" else "") + "}"

    protected fun pullJson(
        cursor: Long,
        items: List<String> = emptyList(),
        hasMore: Boolean = false,
        deletedItems: List<String> = emptyList(),
        tags: String = "",
    ) = """{"cursor":$cursor,"hasMore":$hasMore,"items":[${items.joinToString(",")}],"tags":[$tags],""" +
        """"deleted":{"items":[${deletedItems.joinToString(",") { "\"$it\"" }}],"tags":[]}}"""

    private object PlainCipher : TokenCipher {
        override fun encrypt(plain: ByteArray) = plain
        override fun decrypt(data: ByteArray) = data
    }
}
