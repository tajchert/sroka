package app.sroka.core.data.push

import app.sroka.core.common.Clock
import app.sroka.core.datastore.PushTokenStore
import app.sroka.core.datastore.SessionStore
import app.sroka.core.datastore.StoredSession
import app.sroka.core.network.ApiResult
import app.sroka.core.network.SessionProvider
import app.sroka.core.network.SrokaApi
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Keeps the server's copy of this device's push token current (repo-root D17, api.md "Push tokens").
 * Used by the `play` registrar; knows nothing about FCM.
 *
 * Every trigger (sign-in, app start, token refresh) goes through [reconcile]: one serialized pass that
 * reads the current token inside the lock, so an older token can never overwrite a newer one. The PUT is
 * skipped while the token is unchanged, was registered for the same account and the last accepted PUT
 * is younger than [REFRESH_MS]; a failed PUT is retried by the next trigger.
 */
@Singleton
class PushTokenSyncer @Inject internal constructor(
    private val api: SrokaApi,
    private val sessionStore: SessionStore,
    private val sessionProvider: SessionProvider,
    private val store: PushTokenStore,
    private val clock: Clock,
) {
    private val mutex = Mutex()

    /** Session token of the sign-out in progress or done: no registration for that session any more. */
    @Volatile private var removedSession: String? = null

    /**
     * Registers the token [currentToken] returns (read under the lock) when signed in and the throttle
     * allows. Returns true when a PUT was made and accepted.
     */
    suspend fun reconcile(currentToken: suspend () -> String?): Boolean = mutex.withLock {
        val start = activeSession() ?: return@withLock false
        val token = currentToken()?.takeIf { it.isNotBlank() } ?: return@withLock false
        // The token fetch can be slow: the session may have been signed out or switched meanwhile.
        val session = activeSession() ?: return@withLock false
        if (session.token != start.token) return@withLock false
        val scope = scopeOf(session)
        val now = clock.now()
        val last = store.last()
        if (last != null && last.token == token && last.scope == scope && now - last.atMillis in 0 until REFRESH_MS) {
            return@withLock false
        }
        val accepted = api.putPushToken(token) is ApiResult.Success
        // Credentials are read at send time: only remember the registration if the account did not change.
        if (accepted && activeSession()?.token == session.token) store.save(token, now, scope)
        accepted
    }

    /**
     * Blocks registration for the current session from now on (even while a registration holds the lock),
     * then DELETEs this device's token (needs the session) and forgets the throttle state.
     */
    suspend fun remove() {
        removedSession = sessionStore.token() ?: return
        mutex.withLock {
            try {
                api.deletePushToken()
            } finally {
                store.clear()
            }
        }
    }

    private suspend fun activeSession(): StoredSession? =
        sessionStore.current()?.takeIf { !it.expired && it.token != removedSession }

    private suspend fun scopeOf(session: StoredSession) = "${sessionProvider.baseUrl()}|${session.email.lowercase()}"

    companion object {
        val REFRESH_MS: Long = TimeUnit.DAYS.toMillis(7)
    }
}
