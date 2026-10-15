package app.sroka.core.data.sync

import android.content.Context
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import app.sroka.core.common.di.ApplicationScope
import app.sroka.core.data.content.ContentStoreImpl
import app.sroka.core.datastore.SessionStore
import app.sroka.core.domain.SyncController
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton

/**
 * App-start hook: creates the notification channel and syncs whenever the app comes to the
 * foreground while signed in (DECISIONS A8 triggers). Call [start] once from `Application.onCreate`
 * (main thread).
 */
@Singleton
class SyncInitializer @Inject internal constructor(
    @ApplicationContext private val context: Context,
    private val syncController: SyncController,
    private val sessionStore: SessionStore,
    private val contentStore: ContentStoreImpl,
    @ApplicationScope private val scope: CoroutineScope,
) {
    private val started = AtomicBoolean(false)

    fun start() {
        if (!started.compareAndSet(false, true)) return
        SyncNotifications.ensureChannel(context)
        // Rows left in DOWNLOADING by a previous process go back to QUEUED before any download starts.
        scope.launch { contentStore.recoverInterrupted() }
        ProcessLifecycleOwner.get().lifecycle.addObserver(
            object : DefaultLifecycleObserver {
                override fun onStart(owner: LifecycleOwner) {
                    scope.launch {
                        val session = sessionStore.current()
                        if (session != null && !session.expired) syncController.requestSync()
                    }
                }
            },
        )
    }
}
