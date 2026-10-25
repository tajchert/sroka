package app.sroka.core.network

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.encodeToString
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import app.sroka.core.model.ExportFormat
import app.sroka.core.model.ImportFormat
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.RequestBody.Companion.asRequestBody
import okio.buffer
import okio.sink
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.File
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal class OkHttpSrokaApi(
    private val client: OkHttpClient,
    private val downloadClient: OkHttpClient,
    private val session: SessionProvider,
    private val json: Json,
    /** Response bodies are read and closed here: never on the caller's (possibly Main) dispatcher. */
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    /** Authenticated client with long write/read timeouts for file uploads. */
    private val uploadClient: OkHttpClient = client,
) : SrokaApi {

    override suspend fun sendOtp(email: String): ApiResult<Unit> =
        execute(post("/api/auth/email-otp/send-verification-otp", json.encodeToString(SendOtpRequest(email, "sign-in")))) { }

    override suspend fun signIn(email: String, otp: String): ApiResult<SignInResult> =
        execute(post("/api/auth/sign-in/email-otp", json.encodeToString(SignInRequest(email, otp)))) { response ->
            val token = response.header("set-auth-token")
            if (token.isNullOrEmpty()) throw IOException("missing set-auth-token")
            val body = response.body.string()
            val userEmail = runCatching { json.decodeFromString<SignInResponse>(body).user?.email }.getOrNull()
            SignInResult(token, userEmail ?: email)
        }

    override suspend fun signOut(): ApiResult<Unit> =
        execute(post("/api/auth/sign-out", "{}")) { }

    override suspend fun push(deviceId: String, ops: List<JsonObject>): ApiResult<PushResponseDto> =
        execute(post("/v1/sync/push", json.encodeToString(PushRequest(deviceId, ops)))) { decode(it) }

    override suspend fun pull(cursor: Long, limit: Int, full: Boolean): ApiResult<PullResponseDto> =
        execute(get("/v1/sync/pull?cursor=$cursor&limit=$limit" + if (full) "&full=1" else "")) { decode(it) }

    override suspend fun contentUrls(itemId: String): ApiResult<ContentUrlsDto> =
        execute(get("/v1/items/${segment(itemId)}/content")) { decode(it) }

    override suspend fun uploadPdf(
        file: File,
        fileName: String,
        tags: List<String>,
        source: String,
        onProgress: (Long, Long) -> Unit,
    ): ApiResult<PdfUploadResponseDto> {
        val base = session.baseUrl().trimEnd('/')
        val url = (base + "/v1/items/pdf").toHttpUrl().newBuilder()
            .addQueryParameter("name", fileName)
            .addQueryParameter("source", source)
            .apply { tags.forEach { addQueryParameter("tag", it) } }
            .build()
        val body = ProgressRequestBody(file.asRequestBody(PDF_TYPE), onProgress)
        return executeWith(uploadClient, Request.Builder().url(url).post(body).build()) { decode(it) }
    }

    override suspend fun getItem(itemId: String): ApiResult<ItemDto> =
        execute(get("/v1/items/${segment(itemId)}")) { decode(it) }

    override suspend fun uploadThumbnail(itemId: String, bytes: ByteArray, contentType: String): ApiResult<ItemDto> =
        execute(request("/v1/items/${segment(itemId)}/thumbnail") { put(bytes.toRequestBody(contentType.toMediaType())) }) {
            decode<ItemResponseDto>(it).item
        }

    override suspend fun me(): ApiResult<MeDto> = execute(get("/v1/me")) { decode(it) }

    override suspend fun config(): ApiResult<ConfigDto> = execute(get("/v1/config")) { decode(it) }

    override suspend fun deleteAccount(): ApiResult<Unit> {
        val body = json.encodeToString(DeleteAccountRequest("DELETE")).toRequestBody(JSON_TYPE)
        return execute(request("/v1/account") { delete(body) }) { }
    }

    override suspend fun download(url: String, dest: File, onProgress: (Long, Long) -> Unit): ApiResult<Unit> {
        val httpUrl = url.toHttpUrlOrNull() ?: return ApiResult.NetworkError(IOException("bad url"))
        val part = File(dest.parentFile, dest.name + ".part")
        val context = currentCoroutineContext()
        var success = false
        try {
            val result = executeWith(downloadClient, Request.Builder().url(httpUrl).get().build()) { response ->
                val total = response.body.contentLength()
                part.parentFile?.mkdirs()
                response.body.source().use { source ->
                    part.sink().buffer().use { sink ->
                        var read = 0L
                        val buffer = okio.Buffer()
                        while (true) {
                            context.ensureActive()
                            val n = source.read(buffer, BUFFER_BYTES)
                            if (n == -1L) break
                            sink.write(buffer, n)
                            read += n
                            onProgress(read, total)
                        }
                    }
                }
                dest.delete()
                if (!part.renameTo(dest)) throw IOException("rename failed")
            }
            success = result is ApiResult.Success
            return result
        } finally {
            if (!success) part.delete()
        }
    }

    override suspend fun createImport(source: File, fileName: String, mimeType: String, format: ImportFormat): ApiResult<JobDto> {
        val body = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("format", format.wire)
            .addFormDataPart("file", fileName, source.asRequestBody(mimeType.toMediaTypeOrNull() ?: OCTET_TYPE))
            .build()
        return execute(request("/v1/imports") { post(body) }) { decode<JobEnvelope>(it).job }
    }

    override suspend fun getImport(id: String): ApiResult<JobDto> =
        execute(get("/v1/imports/${segment(id)}")) { decode<JobEnvelope>(it).job }

    override suspend fun export(format: ExportFormat, dest: File): ApiResult<ExportFileDto> {
        val part = File(dest.parentFile, dest.name + ".part")
        val context = currentCoroutineContext()
        var success = false
        try {
            // The authenticated client, not downloadClient: this is a /v1 call.
            val result = executeWith(client, get("/v1/exports?format=${format.wire}")) { response ->
                part.parentFile?.mkdirs()
                var read = 0L
                response.body.source().use { source ->
                    part.sink().buffer().use { sink ->
                        val buffer = okio.Buffer()
                        while (true) {
                            context.ensureActive()
                            val n = source.read(buffer, BUFFER_BYTES)
                            if (n == -1L) break
                            sink.write(buffer, n)
                            read += n
                        }
                    }
                }
                dest.delete()
                if (!part.renameTo(dest)) throw IOException("rename failed")
                ExportFileDto(exportFileName(response.header("Content-Disposition"), format), read)
            }
            success = result is ApiResult.Success
            return result
        } finally {
            if (!success) part.delete()
        }
    }

    // --- plumbing ---

    private suspend fun get(path: String): Request = request(path) { get() }

    private suspend fun post(path: String, body: String): Request =
        request(path) { post(body.toRequestBody(JSON_TYPE)) }

    private suspend fun request(path: String, configure: Request.Builder.() -> Request.Builder): Request {
        val base = session.baseUrl().trimEnd('/')
        return Request.Builder().url((base + path).toHttpUrl()).configure().build()
    }

    private suspend fun <T> execute(request: Request, parse: (Response) -> T): ApiResult<T> =
        executeWith(client, request, parse)

    private suspend fun <T> executeWith(client: OkHttpClient, request: Request, parse: (Response) -> T): ApiResult<T> =
        withContext(ioDispatcher) { executeBlockingParts(client, request, parse) }

    private suspend fun <T> executeBlockingParts(client: OkHttpClient, request: Request, parse: (Response) -> T): ApiResult<T> =
        try {
            client.newCall(request).await().use { response ->
                if (response.isSuccessful) {
                    ApiResult.Success(parse(response))
                } else {
                    errorOf(response)
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: IOException) {
            ApiResult.NetworkError(e)
        } catch (e: kotlinx.serialization.SerializationException) {
            ApiResult.NetworkError(IOException("bad response", e))
        }

    private fun errorOf(response: Response): ApiResult.HttpError {
        val text = runCatching { response.body.string() }.getOrDefault("")
        val parsed = runCatching { json.decodeFromString<ErrorBody>(text) }.getOrNull()
        val retry = (response.header("Retry-After") ?: response.header("X-Retry-After"))?.trim()?.toLongOrNull()
        return ApiResult.HttpError(response.code, parsed?.code ?: parsed?.error, retry)
    }

    private inline fun <reified T> decode(response: Response): T = json.decodeFromString(response.body.string())

    private fun segment(id: String): String = okhttp3.HttpUrl.Builder().scheme("http").host("x")
        .addPathSegment(id).build().encodedPathSegments.last()

    private fun String.toHttpUrlOrNull() = runCatching { toHttpUrl() }.getOrNull()

    private companion object {
        val JSON_TYPE = "application/json; charset=utf-8".toMediaType()
        val PDF_TYPE = "application/pdf".toMediaType()
        val OCTET_TYPE = "application/octet-stream".toMediaType()
        const val BUFFER_BYTES = 16L * 1024
    }
}

private suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    cont.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (cont.isActive) cont.resumeWithException(e)
        }

        override fun onResponse(call: Call, response: Response) {
            if (cont.isActive) cont.resume(response) else response.close()
        }
    })
}

/** Streams the wrapped body unchanged (known length) and reports bytes written to the socket. */
private class ProgressRequestBody(
    private val delegate: RequestBody,
    private val onProgress: (Long, Long) -> Unit,
) : RequestBody() {
    override fun contentType() = delegate.contentType()

    override fun contentLength() = delegate.contentLength()

    override fun writeTo(sink: okio.BufferedSink) {
        val total = contentLength()
        var sent = 0L
        val counting = object : okio.ForwardingSink(sink) {
            override fun write(source: okio.Buffer, byteCount: Long) {
                super.write(source, byteCount)
                sent += byteCount
                onProgress(sent, total)
            }
        }.buffer()
        delegate.writeTo(counting)
        counting.flush()
    }
}
