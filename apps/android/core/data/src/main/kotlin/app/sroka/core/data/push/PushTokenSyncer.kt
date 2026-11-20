package app.sroka.core.data.push

import app.sroka.core.common.Clock
import app.sroka.core.datastore.PushTokenStore
import app.sroka.core.datastore.SessionStore
import app.sroka.core.network.ApiResult
import app.sroka.core.network.SrokaApi
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import javax.inject.Inject
import javax.inject.Singleton
import java.util.concurrent.TimeUnit

/**
 * Keeps the server's copy of this device's push token current (repo-root D17, api.md "Push tokens").
 * Used by the `play` registrar and message service; knows nothing about FCM.
 *
 * The PUT is skipped while the token is unchanged and the last accepted PUT is younger than
 * [REFRESH_MS]; a failed PUT is simply retried by the next trigger (app start / token refresh).
 */
@Singleton
class PushTokenSyncer @Inject internal constructor(
    private val api: SrokaApi,
    private val sessionStore: SessionStore,
    private val store: PushTokenStore,
    private val clock: Clock,
) {
    private val mutex = Mutex()

    /** Registers [token] when signed in and the throttle allows. Returns true when a PUT was made and accepted. */
    suspend fun sync(token: String): Boolean {
        if (token.isBlank()) return false
        val session = sessionStore.current()
        if (session == null || session.expired) return false
        return mutex.withLock {
            val now = clock.now()
            val last = store.last()
            if (last != null && last.token == token && now - last.atMillis in 0 until REFRESH_MS) return@withLock false
            when (api.putPushToken(token)) {
                is ApiResult.Success -> {
                    store.save(token, now)
                    true
                }
                else -> false
            }
        }
    }

    /** DELETE for this device (needs the session) and forget the throttle state. Never throws except for cancellation. */
    suspend fun remove() {
        mutex.withLock {
            try {
                api.deletePushToken()
            } finally {
                store.clear()
            }
        }
    }

    companion object {
        val REFRESH_MS: Long = TimeUnit.DAYS.toMillis(7)
    }
}
