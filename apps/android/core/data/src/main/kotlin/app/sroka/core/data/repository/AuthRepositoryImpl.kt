package app.sroka.core.data.repository

import app.sroka.core.database.dao.ItemDao
import app.sroka.core.database.dao.PendingOpDao
import app.sroka.core.datastore.SessionStore
import app.sroka.core.domain.AuthError
import app.sroka.core.domain.AuthRepository
import app.sroka.core.domain.AuthResult
import app.sroka.core.domain.SyncController
import app.sroka.core.model.SessionState
import app.sroka.core.network.ApiResult
import app.sroka.core.network.SessionProvider
import app.sroka.core.network.SrokaApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withTimeoutOrNull
import javax.inject.Inject
import javax.inject.Singleton

/** Email OTP sign-in (api.md §2.1, DECISIONS A5/A6). 401 elsewhere only marks the session expired. */
@Singleton
internal class AuthRepositoryImpl @Inject constructor(
    private val api: SrokaApi,
    private val sessionStore: SessionStore,
    private val accountMarker: AccountMarker,
    private val wiper: LocalDataWiper,
    private val itemDao: ItemDao,
    private val pendingOpDao: PendingOpDao,
    private val syncController: SyncController,
    private val sessionProvider: SessionProvider,
) : AuthRepository {

    override val session: Flow<SessionState> = sessionStore.session
        .map { stored ->
            when {
                stored == null -> SessionState.SignedOut
                stored.expired -> SessionState.Expired(stored.email)
                else -> SessionState.SignedIn(stored.email)
            }
        }
        .distinctUntilChanged()

    override suspend fun sendCode(email: String): AuthResult {
        val address = email.trim()
        if (!isValidEmail(address)) return AuthResult.Failure(AuthError.InvalidEmail)
        return when (val r = api.sendOtp(address)) {
            is ApiResult.Success -> AuthResult.Success
            is ApiResult.HttpError -> AuthResult.Failure(authError(r))
            is ApiResult.NetworkError -> AuthResult.Failure(AuthError.Network)
        }
    }

    override suspend fun signIn(email: String, code: String): AuthResult {
        val address = email.trim()
        if (!isValidEmail(address)) return AuthResult.Failure(AuthError.InvalidEmail)
        val otp = code.filter { !it.isWhitespace() }
        if (otp.isEmpty()) return AuthResult.Failure(AuthError.InvalidCode)
        return when (val r = api.signIn(address, otp)) {
            is ApiResult.HttpError -> AuthResult.Failure(authError(r))
            is ApiResult.NetworkError -> AuthResult.Failure(AuthError.Network)
            is ApiResult.Success -> {
                val signedInAs = r.value.userEmail.ifBlank { address }
                val owner = accountMarker.email ?: sessionStore.current()?.email
                val server = sessionProvider.baseUrl()
                val dataServer = accountMarker.serverUrl
                val otherAccount = when {
                    owner == null -> hasLocalData()
                    !owner.equals(signedInAs, ignoreCase = true) -> true
                    // Same email on a different server is a different account.
                    else -> dataServer != null && dataServer != server
                }
                if (otherAccount) wiper.wipe()
                sessionStore.save(r.value.token, signedInAs)
                accountMarker.email = signedInAs
                accountMarker.serverUrl = server
                syncController.requestSync()
                AuthResult.Success
            }
        }
    }

    override suspend fun signOut() {
        // Best effort: never block sign-out on the network.
        withTimeoutOrNull(SIGN_OUT_TIMEOUT_MS) { api.signOut() }
        clearLocal()
    }

    /** Also used after account deletion. */
    suspend fun clearLocal() {
        wiper.wipe()
        sessionStore.clear()
        accountMarker.email = null
        accountMarker.serverUrl = null
    }

    private suspend fun hasLocalData(): Boolean {
        val counts = itemDao.observeCounts().first()
        return counts.unread + counts.archived > 0 || pendingOpDao.count() > 0
    }

    private companion object {
        const val SIGN_OUT_TIMEOUT_MS = 5_000L
        val EMAIL = Regex("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$")

        fun isValidEmail(email: String) = email.length <= 254 && EMAIL.matches(email)

        fun authError(r: ApiResult.HttpError): AuthError = when {
            r.status == 429 -> AuthError.RateLimited(r.retryAfterSec)
            r.code == "INVALID_OTP" -> AuthError.InvalidCode
            r.code == "OTP_EXPIRED" -> AuthError.CodeExpired
            r.code == "TOO_MANY_ATTEMPTS" -> AuthError.TooManyAttempts
            r.code == "INVALID_EMAIL" -> AuthError.InvalidEmail
            else -> AuthError.Server
        }
    }
}
