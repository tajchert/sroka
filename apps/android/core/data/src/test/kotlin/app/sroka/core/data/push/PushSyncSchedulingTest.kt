package app.sroka.core.data.push

import android.content.Context
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.test.core.app.ApplicationProvider
import androidx.work.Configuration
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.testing.WorkManagerTestInitHelper
import app.sroka.core.data.sync.SyncWork
import app.sroka.core.data.sync.WorkScheduler
import app.sroka.core.datastore.UserPreferencesDataSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNotEquals
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Push-triggered sync never gets swallowed by a waiting sync (repo-root D17). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PushSyncSchedulingTest {
    @get:Rule val tmp = TemporaryFolder()
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private lateinit var workManager: WorkManager
    private lateinit var scheduler: WorkScheduler

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        WorkManagerTestInitHelper.initializeTestWorkManager(context, Configuration.Builder().build())
        workManager = WorkManager.getInstance(context)
        val prefs = UserPreferencesDataSource(PreferenceDataStoreFactory.create(scope = scope) { tmp.root.resolve("p.preferences_pb") })
        scheduler = WorkScheduler(context, prefs)
    }

    @After
    fun tearDown() = scope.cancel()

    private fun states(name: String) = workManager.getWorkInfosForUniqueWork(name).get().map { it.state }

    @Test fun waitingSyncIsReplacedByAFreshRun() = runBlocking {
        scheduler.enqueueSync() // CONNECTED constraint is unmet in the test environment: stays ENQUEUED
        val first = workManager.getWorkInfosForUniqueWork(SyncWork.SYNC).get().single().id
        scheduler.enqueuePushSync()
        val infos = workManager.getWorkInfosForUniqueWork(SyncWork.SYNC).get()
        val fresh = infos.single()
        assertEquals(WorkInfo.State.ENQUEUED, fresh.state)
        assertNotEquals(first, fresh.id)
        assertEquals(emptyList<WorkInfo.State>(), states(SyncWork.SYNC_PUSH))
    }

    @Test fun pushSyncIsExpeditedOnlyFromApi31() {
        assertFalse(WorkScheduler.pushSyncExpedited(26))
        assertFalse(WorkScheduler.pushSyncExpedited(30))
        assertTrue(WorkScheduler.pushSyncExpedited(31))
        assertTrue(WorkScheduler.pushSyncExpedited(34))
    }
}
