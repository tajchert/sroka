package app.sroka.core.network

import kotlinx.serialization.json.JsonObject
import java.io.File

/** Hand-written client for the Sroka server (api.md; DECISIONS A5). */
interface SrokaApi {
    suspend fun sendOtp(email: String): ApiResult<Unit>

    suspend fun signIn(email: String, otp: String): ApiResult<SignInResult>

    suspend fun signOut(): ApiResult<Unit>

    suspend fun push(deviceId: String, ops: List<JsonObject>): ApiResult<PushResponseDto>

    /** 410 surfaces as [ApiResult.HttpError] with code `resync_required`. */
    suspend fun pull(cursor: Long, limit: Int = 500): ApiResult<PullResponseDto>

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
}
