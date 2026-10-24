package app.sroka.core.network

import kotlinx.serialization.json.JsonObject
import app.sroka.core.model.ExportFormat
import app.sroka.core.model.ImportFormat
import java.io.File

/** Hand-written client for the Sroka server (api.md; DECISIONS A5). */
interface SrokaApi {
    suspend fun sendOtp(email: String): ApiResult<Unit>

    suspend fun signIn(email: String, otp: String): ApiResult<SignInResult>

    suspend fun signOut(): ApiResult<Unit>

    suspend fun push(deviceId: String, ops: List<JsonObject>): ApiResult<PushResponseDto>

    /**
     * 410 surfaces as [ApiResult.HttpError] with code `resync_required`. [full] (`full=1`) marks a
     * pass that started at cursor 0 and continues it with later cursors: the server must not answer
     * 410 for it (api.md §7.2).
     */
    suspend fun pull(cursor: Long, limit: Int = 500, full: Boolean = false): ApiResult<PullResponseDto>

    /** 409 `not_parsed` when the item has no content yet. */
    suspend fun contentUrls(itemId: String): ApiResult<ContentUrlsDto>

    suspend fun getItem(itemId: String): ApiResult<ItemDto>

    suspend fun me(): ApiResult<MeDto>

    suspend fun config(): ApiResult<ConfigDto>

    suspend fun deleteAccount(): ApiResult<Unit>

    /**
     * Streams the unauthenticated (signed) [url] into [dest] via a `.part` file that is renamed on
     * success, so [dest] is never half-written. [onProgress] gets (bytesRead, totalBytes or -1).
     */
    suspend fun download(url: String, dest: File, onProgress: (Long, Long) -> Unit = { _, _ -> }): ApiResult<Unit>

    /** `POST /v1/imports` (multipart `file` + `format`). 413 too large, 429 `rate_limited`, 400 bad file, 503 unavailable. */
    suspend fun createImport(source: File, fileName: String, mimeType: String, format: ImportFormat): ApiResult<JobDto>

    suspend fun getImport(id: String): ApiResult<JobDto>

    /**
     * Streams `GET /v1/exports?format=` into [dest] (via a `.part` file). The name comes from
     * `Content-Disposition`, falling back to `sroka-export-YYYY-MM-DD.ext`.
     */
    suspend fun export(format: ExportFormat, dest: File): ApiResult<ExportFileDto>
}
