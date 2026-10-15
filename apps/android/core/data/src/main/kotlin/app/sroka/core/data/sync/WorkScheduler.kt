package app.sroka.core.data.sync

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.workDataOf
import app.sroka.core.datastore.UserPreferencesDataSource
import app.sroka.core.model.DownloadPolicy
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.first
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/** Unique work names and tags (DECISIONS A8/A9). */
object SyncWork {
    const val SYNC = "sroka-sync"
    const val PERIODIC_SYNC = "sroka-sync-periodic"
    const val DOWNLOAD = "sroka-download"
    const val ITEM_DOWNLOAD_PREFIX = "sroka-download-item-"

    /** Every Sroka work request (cancelled together on sign-out). */
    const val TAG_ALL = "sroka"
    const val TAG_SYNC = "sroka-tag-sync"
    const val TAG_DOWNLOAD = "sroka-tag-download"

    // Input / progress / output data keys.
    const val KEY_USER = "user"
    const val KEY_ITEM_ID = "itemId"
    const val KEY_DONE = "done"
    const val KEY_TOTAL = "total"
    const val KEY_TITLE = "title"
    const val KEY_DOWNLOADED = "downloaded"
}

/** All WorkManager enqueueing lives here so policies and constraints stay consistent. */
@Singleton
class WorkScheduler @Inject internal constructor(
    @ApplicationContext private val context: Context,
    private val preferences: UserPreferencesDataSource,
) {
    private val workManager: WorkManager get() = WorkManager.getInstance(context)

    /** Background sync (push + pull), then auto-download per policy. */
    fun enqueueSync() {
        workManager.enqueueUniqueWork(SyncWork.SYNC, ExistingWorkPolicy.APPEND_OR_REPLACE, syncRequest(user = false))
    }

    /** "Fetch new articles": sync → download as one continuation; any network (explicit user action). */
    fun enqueueFetch() {
        workManager
            .beginUniqueWork(SyncWork.SYNC, ExistingWorkPolicy.APPEND_OR_REPLACE, syncRequest(user = true))
            .then(downloadRequest(user = true, network = NetworkType.CONNECTED))
            .enqueue()
    }

    /** Automatic download after a background sync; MANUAL policy enqueues nothing. */
    suspend fun enqueueAutoDownload() {
        val network = networkFor(preferences.userPreferences.first().downloadPolicy) ?: return
        workManager.enqueueUniqueWork(SyncWork.DOWNLOAD, ExistingWorkPolicy.KEEP, downloadRequest(user = false, network = network))
    }

    /** Re-applies constraints of a waiting automatic download; a running one is left alone. */
    suspend fun onDownloadPolicyChanged(policy: DownloadPolicy) {
        val running = workManager.getWorkInfosForUniqueWorkFlow(SyncWork.DOWNLOAD).first()
            .any { it.state == WorkInfo.State.RUNNING }
        if (running) return
        val network = networkFor(policy)
        if (network == null) {
            workManager.cancelUniqueWork(SyncWork.DOWNLOAD)
        } else {
            workManager.enqueueUniqueWork(SyncWork.DOWNLOAD, ExistingWorkPolicy.REPLACE, downloadRequest(user = false, network = network))
        }
    }

    /** One item now (reader), any network. */
    fun enqueueItemDownload(itemId: String) {
        val request = OneTimeWorkRequestBuilder<ContentDownloadWorker>()
            .setInputData(workDataOf(SyncWork.KEY_ITEM_ID to itemId, SyncWork.KEY_USER to true))
            .setConstraints(Constraints(requiredNetworkType = NetworkType.CONNECTED))
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .addTag(SyncWork.TAG_ALL)
            .build()
        workManager.enqueueUniqueWork(SyncWork.ITEM_DOWNLOAD_PREFIX + itemId, ExistingWorkPolicy.KEEP, request)
    }

    /** Hourly background sync while connected (KEEP: idempotent). */
    fun schedulePeriodicSync() {
        val request = PeriodicWorkRequestBuilder<SyncWorker>(1, TimeUnit.HOURS)
            .setConstraints(Constraints(requiredNetworkType = NetworkType.CONNECTED))
            .addTag(SyncWork.TAG_ALL)
            .addTag(SyncWork.TAG_SYNC)
            .build()
        workManager.enqueueUniquePeriodicWork(SyncWork.PERIODIC_SYNC, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    /** Sign-out / account deletion: stop and forget every Sroka work request. */
    fun cancelAll() {
        workManager.cancelAllWorkByTag(SyncWork.TAG_ALL)
        workManager.pruneWork()
    }

    private fun syncRequest(user: Boolean): OneTimeWorkRequest {
        val builder = OneTimeWorkRequestBuilder<SyncWorker>()
            .setInputData(workDataOf(SyncWork.KEY_USER to user))
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, BACKOFF_SECONDS, TimeUnit.SECONDS)
            .addTag(SyncWork.TAG_ALL)
            .addTag(SyncWork.TAG_SYNC)
        // A user fetch fails fast when offline (the UI reports it); background syncs wait for a network.
        if (!user) builder.setConstraints(Constraints(requiredNetworkType = NetworkType.CONNECTED))
        return builder.build()
    }

    private fun downloadRequest(user: Boolean, network: NetworkType): OneTimeWorkRequest =
        OneTimeWorkRequestBuilder<ContentDownloadWorker>()
            .setInputData(workDataOf(SyncWork.KEY_USER to user))
            .setConstraints(Constraints(requiredNetworkType = network))
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, BACKOFF_SECONDS, TimeUnit.SECONDS)
            .addTag(SyncWork.TAG_ALL)
            .addTag(SyncWork.TAG_DOWNLOAD)
            .build()

    private fun networkFor(policy: DownloadPolicy): NetworkType? = when (policy) {
        DownloadPolicy.WIFI_ONLY -> NetworkType.UNMETERED
        DownloadPolicy.ANY_NETWORK -> NetworkType.CONNECTED
        DownloadPolicy.MANUAL -> null
    }

    private companion object {
        const val BACKOFF_SECONDS = 30L
    }
}
