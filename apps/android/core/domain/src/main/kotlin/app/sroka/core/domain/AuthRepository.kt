package app.sroka.core.domain

import app.sroka.core.model.SessionState
import kotlinx.coroutines.flow.Flow

/** Email one-time-code sign-in (api.md §2.1, DECISIONS A5/A6). */
interface AuthRepository {

    /** Current session; emits immediately. */
    val session: Flow<SessionState>

    /** Sends a 6-digit code to [email]. */
    suspend fun sendCode(email: String): AuthResult

    /**
     * Verifies [code] and stores the session token. Signing in as a different account than the one
     * whose data is on the device wipes local data first; the same account keeps it.
     */
    suspend fun signIn(email: String, code: String): AuthResult

    /** Signs out (best-effort server call), wipes local library data, files and pending ops. */
    suspend fun signOut()
}

sealed interface AuthResult {
    data object Success : AuthResult

    data class Failure(val error: AuthError) : AuthResult
}

sealed interface AuthError {
    data object InvalidEmail : AuthError

    /** Wrong code (`INVALID_OTP`). */
    data object InvalidCode : AuthError

    /** `OTP_EXPIRED`: request a new code. */
    data object CodeExpired : AuthError

    /** `TOO_MANY_ATTEMPTS`: request a new code. */
    data object TooManyAttempts : AuthError

    /** 429; [retryAfterSeconds] from `X-Retry-After` when present. */
    data class RateLimited(val retryAfterSeconds: Long?) : AuthError

    data object Network : AuthError

    data object Server : AuthError
}
