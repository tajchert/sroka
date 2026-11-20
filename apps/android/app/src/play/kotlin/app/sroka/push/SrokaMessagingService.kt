package app.sroka.push

import app.sroka.core.common.di.ApplicationScope
import app.sroka.core.data.push.PushMessageHandler
import app.sroka.core.data.push.PushTokenSyncer
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import javax.inject.Inject

/**
 * Receives the data-only silent push (repo-root D17). `type == "sync"` enqueues the normal
 * background sync, which chains the policy-respecting content download; no UI, no permission.
 */
@AndroidEntryPoint
internal class SrokaMessagingService : FirebaseMessagingService() {
    @Inject lateinit var handler: PushMessageHandler
    @Inject lateinit var syncer: PushTokenSyncer
    @Inject @ApplicationScope lateinit var scope: CoroutineScope

    override fun onNewToken(token: String) {
        // Ignored when signed out; the sign-in registers the then-current token.
        scope.launch {
            try {
                syncer.sync(token)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
            }
        }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        // Enqueueing is a quick WorkManager call; do it before the ~20 s service window ends.
        try {
            runBlocking { handler.onMessage(message.data) }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
        }
    }
}
