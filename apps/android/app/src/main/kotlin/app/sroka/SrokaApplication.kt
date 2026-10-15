package app.sroka

import android.app.Application
import androidx.hilt.work.HiltWorkerFactory
import androidx.work.Configuration
import app.sroka.core.data.sync.SyncInitializer
import dagger.hilt.android.HiltAndroidApp
import javax.inject.Inject

/**
 * Hilt application. Provides WorkManager's configuration so workers (sync, downloads) get their
 * dependencies through [HiltWorkerFactory]; the default WorkManager initializer is removed in the
 * manifest. On start it creates the download notification channel and registers the
 * foreground-sync trigger (sync whenever the app comes to the foreground while signed in).
 */
@HiltAndroidApp
class SrokaApplication : Application(), Configuration.Provider {

    @Inject
    lateinit var workerFactory: HiltWorkerFactory

    @Inject
    lateinit var syncInitializer: SyncInitializer

    override fun onCreate() {
        super.onCreate()
        syncInitializer.start()
    }

    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder()
            .setWorkerFactory(workerFactory)
            .build()
}
