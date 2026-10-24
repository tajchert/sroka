package app.sroka.core.data

import android.content.Context
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.test.core.app.ApplicationProvider
import app.sroka.core.data.transfer.DataTransferRepositoryImpl
import app.sroka.core.data.transfer.ImportJobStore
import app.sroka.core.data.transfer.ImportScheduler
import app.sroka.core.data.transfer.PollEnd
import app.sroka.core.data.transfer.PollOutcome
import app.sroka.core.data.transfer.pollUntilFinished
import app.sroka.core.datastore.SessionStore
import app.sroka.core.datastore.TokenCipher
import app.sroka.core.domain.DataTransferRepository
import app.sroka.core.domain.ExportError
import app.sroka.core.domain.ExportResult
import app.sroka.core.domain.ImportError
import app.sroka.core.domain.ImportStartResult
import app.sroka.core.model.ExportFormat
import app.sroka.core.model.ImportFormat
import app.sroka.core.model.JobStatus
import app.sroka.core.network.NetworkConfig
import app.sroka.core.network.SessionProvider
import app.sroka.core.network.SrokaApiFactory
import app.sroka.core.testing.fake.testImportJob
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.io.RandomAccessFile

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class DataTransferTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val server = MockWebServer()
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private lateinit var context: Context
    private lateinit var store: ImportJobStore
    private lateinit var sessionStore: SessionStore
    private lateinit var repo: DataTransferRepositoryImpl
    private val scheduled = mutableListOf<String>()

    private object PlainCipher : TokenCipher {
        override fun encrypt(plain: ByteArray) = plain
        override fun decrypt(cipher: ByteArray) = cipher
    }

    @Before
    fun setUp() {
        server.start()
        context = ApplicationProvider.getApplicationContext()
        store = ImportJobStore(PreferenceDataStoreFactory.create(scope = scope) { tmp.newFile("prefs.preferences_pb").also { it.delete() } })
        sessionStore = SessionStore(PreferenceDataStoreFactory.create(scope = scope) { tmp.newFile("s.preferences_pb").also { it.delete() } }, PlainCipher)
        runBlocking { sessionStore.save("tok", "me@example.com") }
        val provider = object : SessionProvider {
            override suspend fun token() = sessionStore.token()
            override suspend fun deviceId() = "and_test"
            override suspend fun baseUrl() = server.url("/").toString().trimEnd('/')
        }
        val api = SrokaApiFactory.create(provider, NetworkConfig("Sroka-Android/test"))
        repo = DataTransferRepositoryImpl(context, api, store, ImportScheduler { scheduled += it }, sessionStore, Dispatchers.IO)
        File(context.cacheDir, "imports").deleteRecursively()
        File(context.cacheDir, "exports").deleteRecursively()
    }

    @After
    fun tearDown() {
        server.close()
        scope.cancel()
    }

    private fun source(name: String = "pocket.csv", bytes: Int = 64): String =
        tmp.newFile(name).apply { writeBytes(ByteArray(bytes) { 'a'.code.toByte() }) }.toURI().toString()

    private fun json(body: String, code: Int = 200) =
        server.enqueue(MockResponse.Builder().code(code).body(body).addHeader("Content-Type", "application/json").build())

    private val jobBody =
        """{"job":{"id":"j1","kind":"import","status":"queued","format":"pocket_csv","total":null,"done":0,"skipped":0,"error":null,"createdAt":5,"updatedAt":5}}"""

    private fun leftovers() = File(context.cacheDir, "imports").listFiles().orEmpty().toList()

    @Test
    fun startImportUploadsPersistsEnqueuesAndCleansUp() = runTest {
        json(jobBody, 202)
        val r = repo.startImport(source(), ImportFormat.POCKET_CSV) as ImportStartResult.Started
        assertEquals("j1", r.job.id)
        assertEquals(JobStatus.QUEUED, r.job.status)
        assertEquals(listOf("j1"), scheduled)
        assertEquals("j1", repo.activeImport().first()?.id)
        assertTrue(leftovers().isEmpty())
        val req = server.takeRequest()
        assertEquals("/v1/imports", req.url.encodedPath)
        assertTrue(req.body!!.utf8().contains("filename=\"pocket.csv\""))
    }

    @Test
    fun clientSideSizeLimit() = runTest {
        val big = tmp.newFile("big.csv")
        RandomAccessFile(big, "rw").use { it.setLength(DataTransferRepository.MAX_IMPORT_BYTES + 1) }
        val r = repo.startImport(big.toURI().toString(), ImportFormat.POCKET_CSV)
        assertEquals(ImportStartResult.Failed(ImportError.TOO_LARGE), r)
        assertEquals(0, server.requestCount)
        assertTrue(leftovers().isEmpty())
        assertNull(repo.activeImport().first())
    }

    @Test
    fun emptyOrMissingFileIsBadFile() = runTest {
        assertEquals(ImportStartResult.Failed(ImportError.BAD_FILE), repo.startImport(source("e.csv", 0), ImportFormat.POCKET_CSV))
        val missing = File(tmp.root, "nope.csv").toURI().toString()
        assertEquals(ImportStartResult.Failed(ImportError.BAD_FILE), repo.startImport(missing, ImportFormat.POCKET_CSV))
        assertEquals(0, server.requestCount)
    }

    @Test
    fun httpErrorsMapToTypedErrors() = runTest {
        val cases = mapOf(
            413 to ImportError.TOO_LARGE, 429 to ImportError.RATE_LIMITED, 400 to ImportError.BAD_FILE,
            415 to ImportError.BAD_FILE, 503 to ImportError.UNAVAILABLE, 418 to ImportError.UNKNOWN,
        )
        for ((status, expected) in cases) {
            json("""{"error":"x"}""", status)
            assertEquals("status $status", ImportStartResult.Failed(expected), repo.startImport(source("f$status.csv"), ImportFormat.POCKET_CSV))
        }
        assertTrue(scheduled.isEmpty())
        assertNull(repo.activeImport().first())
        assertTrue(leftovers().isEmpty())
    }

    @Test
    fun unauthorizedExpiresSession() = runTest {
        json("""{"error":"unauthorized"}""", 401)
        assertEquals(ImportStartResult.Failed(ImportError.SIGNED_OUT), repo.startImport(source(), ImportFormat.POCKET_CSV))
        assertTrue(sessionStore.current()!!.expired)
    }

    @Test
    fun networkFailureMaps() = runTest {
        val src = source()
        server.close()
        assertEquals(ImportStartResult.Failed(ImportError.NETWORK), repo.startImport(src, ImportFormat.POCKET_CSV))
    }

    @Test
    fun activeJobPersistsDismissAndGuardedUpdate() = runTest {
        store.set(testImportJob(id = "a"))
        assertEquals("a", repo.activeImport().first()?.id)
        store.update(testImportJob(id = "b", done = 5))
        assertEquals("a", store.current()?.id)
        store.update(testImportJob(id = "a", status = JobStatus.RUNNING, total = 9, done = 4))
        assertEquals(4, store.current()?.done)
        repo.dismissImport()
        assertNull(repo.activeImport().first())
    }

    @Test
    fun fileInfoReadsNameAndSize() {
        val info = repo.fileInfo(source("p.zip", 10))
        assertEquals("p.zip", info?.name)
        assertEquals(10L, info?.sizeBytes)
    }

    @Test
    fun exportWritesNamedFileAndReplacesOlder() = runTest {
        val dir = File(context.cacheDir, "exports").apply { mkdirs() }
        File(dir, "old.csv").writeText("old")
        server.enqueue(
            MockResponse.Builder().code(200).body("title,url\n")
                .addHeader("Content-Disposition", "attachment; filename=\"sroka-export-2026-10-23.csv\"").build(),
        )
        val r = repo.export(ExportFormat.CSV) as ExportResult.Ready
        assertEquals("sroka-export-2026-10-23.csv", r.fileName)
        assertEquals(10L, r.bytes)
        assertEquals(File(dir, r.fileName).absolutePath, r.path)
        assertEquals(listOf(r.fileName), dir.list()!!.toList())
    }

    @Test
    fun exportErrorMapping() = runTest {
        json("{}", 500)
        assertEquals(ExportResult.Failed(ExportError.SERVER), repo.export(ExportFormat.JSON))
        json("{}", 401)
        assertEquals(ExportResult.Failed(ExportError.SIGNED_OUT), repo.export(ExportFormat.JSON))
        server.close()
        assertEquals(ExportResult.Failed(ExportError.NETWORK), repo.export(ExportFormat.JSON))
    }

    @Test
    fun pollLoopStopsWhenFinished() = runTest {
        val seq = ArrayDeque(
            listOf(
                PollOutcome.Updated(testImportJob(status = JobStatus.RUNNING, total = 4, done = 1)),
                PollOutcome.Transient,
                PollOutcome.Updated(testImportJob(status = JobStatus.DONE, total = 4, done = 4)),
            ),
        )
        val seen = mutableListOf<JobStatus>()
        val end = pollUntilFinished(1, 5, { seq.removeFirst() }, { seen += it.status })
        assertEquals(PollEnd.FINISHED, end)
        assertEquals(listOf(JobStatus.RUNNING, JobStatus.DONE), seen)
    }

    @Test
    fun pollLoopGivesUpAfterConsecutiveErrorsAndStops() = runTest {
        assertEquals(PollEnd.TOO_MANY_ERRORS, pollUntilFinished(1, 3, { PollOutcome.Transient }, {}))
        assertEquals(PollEnd.STOPPED, pollUntilFinished(1, 3, { PollOutcome.Stop }, {}))
    }
}
