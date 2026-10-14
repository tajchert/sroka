package app.sroka

import android.app.Application
import androidx.hilt.work.HiltWorkerFactory
import androidx.work.Configuration
import dagger.hilt.android.HiltAndroidApp
import javax.inject.Inject

/**
 * Hilt application. Provides WorkManager's configuration so workers (sync, downloads) get their
 * dependencies through [HiltWorkerFactory]; the default WorkManager initializer is removed in the
 * manifest.
 */
@HiltAndroidApp
class SrokaApplication : Application(), Configuration.Provider {

    @Inject
    lateinit var workerFactory: HiltWorkerFactory

    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder()
            .setWorkerFactory(workerFactory)
            .build()
}
