package app.sroka.push

import app.sroka.core.data.push.PushTokenSyncer
import app.sroka.core.domain.PushRegistrar
import com.google.android.gms.tasks.Task
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.resume

/**
 * FCM side of the silent sync push (repo-root D17). Token fetching lives here; the throttle and the
 * HTTP calls are in core:data's [PushTokenSyncer]. Without a Firebase config (no google-services.json)
 * `FirebaseMessaging` is unavailable and both calls do nothing.
 */
@Singleton
internal class FirebasePushRegistrar @Inject constructor(
    private val syncer: PushTokenSyncer,
) : PushRegistrar {

    /** The in-flight `deleteToken()`; it can outlive the sign-out timeout, so a quick re-sign-in waits for it. */
    @Volatile private var pendingDelete: Task<Void>? = null

    /** All triggers (sign-in, app start, `onNewToken`) land here; the token is read inside the syncer's lock. */
    override suspend fun register() {
        syncer.reconcile(::fcmToken)
    }

    override suspend fun unregister() {
        try {
            syncer.remove()
        } finally {
            // The next sign-in then gets a fresh token instead of reusing one the server just forgot.
            val task = runCatching { messaging()?.deleteToken() }.getOrNull()
            pendingDelete = task
            runCatching { task?.await() }
        }
    }

    private suspend fun fcmToken(): String? =
        try {
            pendingDelete?.let { withTimeoutOrNull(DELETE_WAIT_MS) { it.await() } }
            messaging()?.token?.await()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }

    private companion object {
        const val DELETE_WAIT_MS = 3_000L
    }

    private fun messaging(): FirebaseMessaging? = runCatching { FirebaseMessaging.getInstance() }.getOrNull()
}

private suspend fun <T> Task<T>.await(): T? = suspendCancellableCoroutine { cont ->
    addOnCompleteListener { task -> if (cont.isActive) cont.resume(if (task.isSuccessful) task.result else null) }
}
