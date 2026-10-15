package app.sroka.core.network

import java.io.IOException

/** Outcome of a [SrokaApi] call (DECISIONS A5). Calls never throw except for coroutine cancellation. */
sealed interface ApiResult<out T> {
    data class Success<T>(val value: T) : ApiResult<T>

    /**
     * Non-2xx answer. [code] is the `error` (api.md §3) or Better Auth `code` field, e.g. `resync_required`,
     * `not_parsed`, `INVALID_OTP`; [retryAfterSec] comes from `Retry-After` / `X-Retry-After`.
     */
    data class HttpError(val status: Int, val code: String?, val retryAfterSec: Long?) : ApiResult<Nothing>

    /** Connectivity problem or timeout. */
    data class NetworkError(val cause: IOException) : ApiResult<Nothing>
}

inline fun <T, R> ApiResult<T>.map(transform: (T) -> R): ApiResult<R> = when (this) {
    is ApiResult.Success -> ApiResult.Success(transform(value))
    is ApiResult.HttpError -> this
    is ApiResult.NetworkError -> this
}
