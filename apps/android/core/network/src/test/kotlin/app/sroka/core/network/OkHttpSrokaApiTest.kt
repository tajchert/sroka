package app.sroka.core.network

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.asCoroutineDispatcher
import okhttp3.ResponseBody.Companion.asResponseBody
import okio.buffer
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.SocketEffect
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.concurrent.TimeUnit

class OkHttpSrokaApiTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val server = MockWebServer()
    private var token: String? = "tok.en=="
    private lateinit var api: SrokaApi

    @Before
    fun setUp() {
        server.start()
        val session = object : SessionProvider {
            override suspend fun token() = token
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

    @Test
    fun sendsAuthDeviceAndUserAgentHeaders() = runBlocking {
        json("""{"user":{"id":"u","email":"a@b.c"},"stats":{"unread":2}}""")
        val r = api.me() as ApiResult.Success
        assertEquals("a@b.c", r.value.user.email)
        assertEquals(2, r.value.stats.unread)
        val req = server.takeRequest()
        assertEquals("/v1/me", req.url.encodedPath)
        assertEquals("Bearer tok.en==", req.headers["Authorization"])
        assertEquals("and_dev1", req.headers["X-Sroka-Device"])
        assertEquals("Sroka-Android/1.0", req.headers["User-Agent"])
    }

    @Test
    fun noAuthHeaderWhenSignedOut() = runBlocking {
        token = null
        json("""{"appOrigin":"https://sroka.app","minVersions":{"android":null},"extra":1}""")
        val r = api.config() as ApiResult.Success
        assertEquals("https://sroka.app", r.value.appOrigin)
        assertNull(server.takeRequest().headers["Authorization"])
    }

    @Test
    fun sendOtpPostsEmailAndType() = runBlocking {
        json("""{"success":true}""")
        assertTrue(api.sendOtp("a@b.c") is ApiResult.Success)
        val req = server.takeRequest()
        assertEquals("POST", req.method)
        assertEquals("/api/auth/email-otp/send-verification-otp", req.url.encodedPath)
        assertEquals("""{"email":"a@b.c","type":"sign-in"}""", req.body!!.utf8())
    }

    @Test
    fun signInCapturesSetAuthTokenVerbatim() = runBlocking {
        json("""{"token":"x","user":{"email":"me@x.io"}}""", 200, "set-auth-token" to "abc.def+g==")
        val r = api.signIn("me@x.io", "123456") as ApiResult.Success
        assertEquals("abc.def+g==", r.value.token)
        assertEquals("me@x.io", r.value.userEmail)
        assertEquals("""{"email":"me@x.io","otp":"123456"}""", server.takeRequest().body!!.utf8())
    }

    @Test
    fun signInWithoutTokenHeaderIsError() = runBlocking {
        json("""{"user":{"email":"me@x.io"}}""")
        assertTrue(api.signIn("me@x.io", "1") is ApiResult.NetworkError)
    }

    @Test
    fun betterAuthErrorCodes() = runBlocking {
        json("""{"code":"INVALID_OTP","message":"bad"}""", 400)
        assertEquals(ApiResult.HttpError(400, "INVALID_OTP", null), api.signIn("a@b.c", "1"))
        json("""{"code":"TOO_MANY_ATTEMPTS"}""", 403)
        assertEquals(ApiResult.HttpError(403, "TOO_MANY_ATTEMPTS", null), api.signIn("a@b.c", "1"))
        json("""{"message":"Too many requests."}""", 429, "X-Retry-After" to "42")
        assertEquals(ApiResult.HttpError(429, null, 42), api.sendOtp("a@b.c"))
    }

    @Test
    fun v1ErrorsAndRetryAfter() = runBlocking {
        json("""{"error":"unauthorized"}""", 401)
        assertEquals(ApiResult.HttpError(401, "unauthorized", null), api.me())
        json("""{"error":"rate_limited"}""", 429, "Retry-After" to "7")
        assertEquals(ApiResult.HttpError(429, "rate_limited", 7), api.me())
        server.enqueue(MockResponse.Builder().code(502).body("<html>bad gateway</html>").build())
        assertEquals(ApiResult.HttpError(502, null, null), api.me())
    }

    @Test
    fun signOutPostsEmptyObject() = runBlocking {
        json("{}")
        assertTrue(api.signOut() is ApiResult.Success)
        val req = server.takeRequest()
        assertEquals("/api/auth/sign-out", req.url.encodedPath)
        assertEquals("{}", req.body!!.utf8())
    }

    @Test
    fun pushSendsDeviceAndOpsAndParsesResponse() = runBlocking {
        json("""{"applied":["a1"],"rejected":[{"opId":"a2","reason":"unknown_item"}],"aliases":{"c":"s"},"cursor":9}""")
        val op = buildJsonObject { put("opId", "a1"); put("type", "item.delete"); put("itemId", "i"); put("at", 1) }
        val r = api.push("and_dev1", listOf(op)) as ApiResult.Success
        assertEquals(listOf("a1"), r.value.applied)
        assertEquals("unknown_item", r.value.rejected.single().reason)
        assertEquals(mapOf("c" to "s"), r.value.aliases)
        assertEquals(9L, r.value.cursor)
        val req = server.takeRequest()
        assertEquals("/v1/sync/push", req.url.encodedPath)
        assertTrue(req.body!!.utf8().startsWith("""{"deviceId":"and_dev1","ops":[{"opId":"a1""""))
    }

    @Test
    fun pullParsesItemsTagsAndDeleted() = runBlocking {
        json(
            """{"cursor":5,"hasMore":true,"items":[{"id":"i1","url":"https://e.com","title":null,
            "leadImageKey":"thumb.webp","parseStatus":"ok","status":"archived","isFavorite":true,"progress":0.5,
            "progressAnchor":3,"savedAt":10,"tags":["a"],"seq":4,"futureField":true}],
            "tags":[{"id":"t","name":"a","seq":3}],"deleted":{"items":["x"],"tags":["y"]}}""",
        )
        val r = api.pull(2, 100) as ApiResult.Success
        val item = r.value.items.single()
        assertEquals("archived", item.status)
        assertEquals(0.5f, item.progress)
        assertEquals(3, item.progressAnchor)
        assertNull(item.title)
        assertTrue(r.value.hasMore)
        assertEquals(listOf("x"), r.value.deleted.items)
        assertEquals("t", r.value.tags.single().id)
        val req = server.takeRequest()
        assertEquals("2", req.url.queryParameter("cursor"))
        assertEquals("100", req.url.queryParameter("limit"))
        assertNull(req.url.queryParameter("full"))
    }

    @Test
    fun pullFullPassSendsFullFlag() = runBlocking {
        json("""{"cursor":5,"hasMore":false,"items":[],"tags":[],"deleted":{"items":[],"tags":[]}}""")
        assertTrue(api.pull(40, 100, full = true) is ApiResult.Success)
        assertEquals("1", server.takeRequest().url.queryParameter("full"))
    }

    @Test
    fun pullGoneIsResyncRequired() = runBlocking {
        json("""{"error":"resync_required"}""", 410)
        assertEquals(ApiResult.HttpError(410, "resync_required", null), api.pull(5))
    }

    @Test
    fun contentUrlsAndNotParsed() = runBlocking {
        json("""{"articleUrl":"a","baseUrl":"b","packageUrl":"p","expiresAt":99}""")
        val r = api.contentUrls("item1") as ApiResult.Success
        assertEquals("p", r.value.packageUrl)
        assertEquals("/v1/items/item1/content", server.takeRequest().url.encodedPath)
        json("""{"error":"not_parsed"}""", 409)
        assertEquals(ApiResult.HttpError(409, "not_parsed", null), api.contentUrls("item1"))
    }

    @Test
    fun getItem() = runBlocking {
        json("""{"id":"i1","url":"https://e.com"}""")
        val r = api.getItem("i1") as ApiResult.Success
        assertEquals("unread", r.value.status)
        assertEquals("/v1/items/i1", server.takeRequest().url.encodedPath)
    }

    @Test
    fun deleteAccountSendsConfirm() = runBlocking {
        json("""{"deleted":true}""")
        assertTrue(api.deleteAccount() is ApiResult.Success)
        val req = server.takeRequest()
        assertEquals("DELETE", req.method)
        assertEquals("/v1/account", req.url.encodedPath)
        assertEquals("""{"confirm":"DELETE"}""", req.body!!.utf8())
    }

    @Test
    fun connectionFailureIsNetworkError() = runBlocking {
        server.enqueue(MockResponse.Builder().onRequestStart(SocketEffect.CloseSocket()).build())
        assertTrue(api.me() is ApiResult.NetworkError)
    }

    @Test
    fun malformedJsonIsNetworkError() = runBlocking {
        json("not json")
        assertTrue(api.me() is ApiResult.NetworkError)
    }

    @Test
    fun downloadStreamsToFileWithProgressAndNoAuth() = runBlocking {
        val bytes = ByteArray(100_000) { (it % 251).toByte() }
        server.enqueue(MockResponse.Builder().body(okio.Buffer().write(bytes)).build())
        val dest = tmp.newFolder("a").resolve("pkg.zip")
        val progress = mutableListOf<Pair<Long, Long>>()
        val r = api.download(server.url("/s/1/sig/p/c/package.zip").toString(), dest) { d, t -> progress += d to t }
        assertTrue(r is ApiResult.Success)
        assertTrue(bytes.contentEquals(dest.readBytes()))
        assertEquals(100_000L to 100_000L, progress.last())
        assertFalse(dest.resolveSibling("pkg.zip.part").exists())
        val req = server.takeRequest()
        assertNull(req.headers["Authorization"])
        assertNull(req.headers["X-Sroka-Device"])
        assertEquals("Sroka-Android/1.0", req.headers["User-Agent"])
    }

    @Test
    fun downloadErrorLeavesNoFile() = runBlocking {
        server.enqueue(MockResponse.Builder().code(403).body("""{"error":"forbidden","message":"expired"}""").build())
        val dest = tmp.newFolder("b").resolve("pkg.zip")
        val r = api.download(server.url("/x").toString(), dest)
        assertEquals(ApiResult.HttpError(403, "forbidden", null), r)
        assertFalse(dest.exists())
        assertFalse(dest.resolveSibling("pkg.zip.part").exists())
    }

    @Test
    fun cancellationStopsCallAndPropagates() = runBlocking {
        server.enqueue(MockResponse.Builder().body("{}").headersDelay(10, TimeUnit.SECONDS).build())
        val started = CompletableDeferred<Unit>()
        val job: Job = launch(kotlinx.coroutines.Dispatchers.IO) {
            started.complete(Unit)
            api.me()
        }
        started.await()
        server.takeRequest(5, TimeUnit.SECONDS)
        job.cancelAndJoin()
        assertTrue(job.isCancelled)
    }

    @Test
    fun cancellationPropagatesFromAsync() = runBlocking {
        server.enqueue(MockResponse.Builder().body("{}").headersDelay(10, TimeUnit.SECONDS).build())
        val d = async(kotlinx.coroutines.Dispatchers.IO) { api.me() }
        server.takeRequest(5, TimeUnit.SECONDS)
        d.cancelAndJoin()
        assertTrue(d.isCancelled)
    }

    @Test
    fun responseBodiesAreReadOnTheIoDispatcherNotTheCaller() = runBlocking {
        val readers = java.util.Collections.synchronizedSet(mutableSetOf<String>())
        val recording = okhttp3.Interceptor { chain ->
            val response = chain.proceed(chain.request())
            val body = response.body
            val source = object : okio.ForwardingSource(body.source()) {
                override fun read(sink: okio.Buffer, byteCount: Long): Long {
                    readers += Thread.currentThread().name
                    return super.read(sink, byteCount)
                }
            }
            response.newBuilder().body(
                source.buffer().asResponseBody(body.contentType(), body.contentLength()),
            ).build()
        }
        val session = object : SessionProvider {
            override suspend fun token() = token
            override suspend fun deviceId() = "and_dev1"
            override suspend fun baseUrl() = server.url("/").toString().trimEnd('/')
        }
        val io = java.util.concurrent.Executors.newSingleThreadExecutor { r -> Thread(r, "test-io") }
        try {
            val client = OkHttpClient.Builder().addInterceptor(recording).build()
            val api = OkHttpSrokaApi(client, client, session, Json { ignoreUnknownKeys = true }, io.asCoroutineDispatcher())
            json("""{"code":"TURNSTILE_FAILED","message":"x"}""", code = 400)
            val r = api.sendOtp("a@b.c") as ApiResult.HttpError
            assertEquals("TURNSTILE_FAILED", r.code)
            json("""{"user":{"id":"u","email":"a@b.c"},"stats":{"unread":2}}""")
            assertTrue(api.me() is ApiResult.Success)
            assertTrue(readers.isNotEmpty())
            assertTrue(readers.toString(), readers.all { it.startsWith("test-io") })
        } finally {
            io.shutdown()
        }
    }
}
