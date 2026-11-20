package app.sroka.core.data.push

import app.sroka.core.data.sync.WorkScheduler
import app.sroka.core.datastore.SessionStore
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Handles a data message from the silent sync push (repo-root D17, api.md "Push tokens"): any
 * `type == "sync"` message means "sync now" while signed in; other types are ignored. It only
 * enqueues the normal background sync, which chains the policy-respecting content download itself.
 */
@Singleton
class PushMessageHandler internal constructor(
    private val isSignedIn: suspend () -> Boolean,
    private val enqueueSync: suspend () -> Unit,
) {
    @Inject internal constructor(
        sessionStore: SessionStore,
        scheduler: WorkScheduler,
    ) : this(
        isSignedIn = { sessionStore.current()?.let { !it.expired } ?: false },
        enqueueSync = scheduler::enqueuePushSync,
    )

    /** Returns true when a sync was enqueued. */
    suspend fun onMessage(data: Map<String, String>): Boolean {
        if (data[TYPE_KEY] != TYPE_SYNC) return false
        if (!isSignedIn()) return false
        enqueueSync()
        return true
    }

    companion object {
        const val TYPE_KEY = "type"
        const val TYPE_SYNC = "sync"
    }
}
