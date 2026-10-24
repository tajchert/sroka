package app.sroka.core.network

import app.sroka.core.model.ExportFormat
import app.sroka.core.model.ImportFormat
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.time.LocalDate

class TransferApiTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val server = MockWebServer()
    private lateinit var api: SrokaApi

    @Before
    fun setUp() {
        server.start()
        val session = object : SessionProvider {
            override suspend fun token() = "tok"
            override suspend fun deviceId() = "and_dev1"
            override suspend fun baseUrl() = server.url("/").toString().trimEnd('/')
        }
        val json = Json { ignoreUnknownKeys = true; explicitNulls = false; coerceInputValues = true }
        val client = OkHttpClient.Builder().addInterceptor(HeaderInterceptor(session, "Sroka-Android/1.0")).build()
        val dl = OkHttpClient.Builder().addInterceptor(UserAgentInterceptor("Sroka-Android/1.0")).build()
        api = OkHttpSrokaApi(client, dl, session, json)
    }

    @After
    fun tearDown() = server.close()

    private fun json(body: String, code: Int = 200, vararg headers: Pair<String, String>) {
        val b = MockResponse.Builder().code(code).body(body).addHeader("Content-Type", "application/json")
        headers.forEach { (k, v) -> b.addHeader(k, v) }
        server.enqueue(b.build())
    }

    private val jobJson =
        """{"job":{"id":"j1","kind":"import","status":"running","format":"pocket_csv","total":10,"done":3,"skipped":1,"error":null,"createdAt":1,"updatedAt":2}}"""

    @Test
    fun createImportSendsMultipartWithFormatAndFile() = runBlocking {
        json(jobJson, 202)
        val file = tmp.newFile("x.csv").apply { writeText("title,url\nA,https://a.example\n") }
        val r = api.createImport(file, "pocket.csv", "text/csv", ImportFormat.POCKET_CSV) as ApiResult.Success
        assertEquals("j1", r.value.id)
        assertEquals(10, r.value.total)
        val req = server.takeRequest()
        assertEquals("POST", req.method)
        assertEquals("/v1/imports", req.url.encodedPath)
        assertEquals("Bearer tok", req.headers["Authorization"])
        assertEquals("and_dev1", req.headers["X-Sroka-Device"])
        assertTrue(req.headers["Content-Type"]!!.startsWith("multipart/form-data"))
        val body = req.body!!.utf8()
        assertTrue(body.contains("name=\"format\""))
        assertTrue(body.contains("pocket_csv"))
        assertTrue(body.contains("name=\"file\"; filename=\"pocket.csv\""))
        assertTrue(body.contains("https://a.example"))
    }

    @Test
    fun createImportMapsTooLargeAndRateLimit() = runBlocking {
        val file = tmp.newFile("y.csv").apply { writeText("a") }
        json("""{"error":"payload_too_large"}""", 413)
        val tooLarge = api.createImport(file, "y.csv", "text/csv", ImportFormat.POCKET_CSV) as ApiResult.HttpError
        assertEquals(413, tooLarge.status)
        assertEquals("payload_too_large", tooLarge.code)
        json("""{"error":"rate_limited"}""", 429, "Retry-After" to "60")
        val limited = api.createImport(file, "y.csv", "text/csv", ImportFormat.POCKET_CSV) as ApiResult.HttpError
        assertEquals(429, limited.status)
        assertEquals("rate_limited", limited.code)
        assertEquals(60L, limited.retryAfterSec)
    }

    @Test
    fun getImportDecodesJob() = runBlocking {
        json(jobJson)
        val r = api.getImport("j1") as ApiResult.Success
        assertEquals("running", r.value.status)
        assertEquals(3, r.value.done)
        assertEquals("/v1/imports/j1", server.takeRequest().url.encodedPath)
    }

    @Test
    fun exportStreamsToFileWithDispositionName() = runBlocking {
        server.enqueue(
            MockResponse.Builder().code(200).body("title,url\n")
                .addHeader("Content-Disposition", "attachment; filename=\"sroka-export-2026-10-23.csv\"").build(),
        )
        val dest = tmp.newFile("out.csv")
        val r = api.export(ExportFormat.CSV, dest) as ApiResult.Success
        assertEquals("sroka-export-2026-10-23.csv", r.value.fileName)
        assertEquals(10L, r.value.bytes)
        assertEquals("title,url\n", dest.readText())
        val req = server.takeRequest()
        assertEquals("/v1/exports", req.url.encodedPath)
        assertEquals("csv", req.url.queryParameter("format"))
        assertEquals("Bearer tok", req.headers["Authorization"])
        assertFalse(java.io.File(dest.parentFile, "out.csv.part").exists())
    }

    @Test
    fun exportErrorLeavesNoFile() = runBlocking {
        json("""{"error":"internal"}""", 500)
        val dest = java.io.File(tmp.root, "e.json")
        assertTrue(api.export(ExportFormat.JSON, dest) is ApiResult.HttpError)
        assertFalse(dest.exists())
    }

    @Test
    fun contentDispositionParsing() {
        val day = LocalDate.of(2026, 1, 2)
        assertEquals("a b.json", exportFileName("attachment; filename=\"a b.json\"", ExportFormat.JSON, day))
        assertEquals("x.csv", exportFileName("attachment; filename=x.csv", ExportFormat.CSV, day))
        assertEquals("żółw.csv", exportFileName("attachment; filename=\"a.csv\"; filename*=UTF-8''%C5%BC%C3%B3%C5%82w.csv", ExportFormat.CSV, day))
        assertEquals("passwd", exportFileName("attachment; filename=\"../../etc/passwd\"", ExportFormat.CSV, day))
        assertEquals("sroka-export-2026-01-02.json", exportFileName(null, ExportFormat.JSON, day))
        assertEquals("sroka-export-2026-01-02.csv", exportFileName("attachment", ExportFormat.CSV, day))
    }
}
