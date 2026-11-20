package app.sroka.push

import app.sroka.core.data.push.PushTokenSyncer
import app.sroka.core.domain.PushRegistrar
import com.google.android.gms.tasks.Task
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
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

    override suspend fun register() {
        val token = fcmToken() ?: return
        syncer.sync(token)
    }

    override suspend fun unregister() {
        try {
            syncer.remove()
        } finally {
            // The next sign-in then gets a fresh token instead of reusing one the server just forgot.
            runCatching { messaging()?.deleteToken()?.await() }
        }
    }

    private suspend fun fcmToken(): String? =
        try {
            messaging()?.token?.await()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }

    private fun messaging(): FirebaseMessaging? = runCatching { FirebaseMessaging.getInstance() }.getOrNull()
}

private suspend fun <T> Task<T>.await(): T? = suspendCancellableCoroutine { cont ->
    addOnCompleteListener { task -> if (cont.isActive) cont.resume(if (task.isSuccessful) task.result else null) }
}
