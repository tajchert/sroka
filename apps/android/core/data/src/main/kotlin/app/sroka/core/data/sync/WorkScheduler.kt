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
import app.sroka.core.data.content.DownloadCanceller
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

    /** A user "Fetch": its own unique name so it never waits behind a constrained background sync. */
    const val FETCH = "sroka-fetch"
    const val PERIODIC_SYNC = "sroka-sync-periodic"
    const val DOWNLOAD = "sroka-download"
    const val ITEM_DOWNLOAD_PREFIX = "sroka-download-item-"

    /** Every Sroka work request (cancelled together on sign-out). */
    const val TAG_ALL = "sroka"
    const val TAG_SYNC = "sroka-tag-sync"
    const val TAG_DOWNLOAD = "sroka-tag-download"

    /** Reader single-item downloads (not part of the bulk-download status). */
    const val TAG_ITEM_DOWNLOAD = "sroka-tag-item-download"

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

    /**
     * Background sync (push + pull), then auto-download per policy. A sync that has not started yet
     * (waiting for a network, or backing off) will pick up the new ops itself, so nothing is added;
     * only a running one gets a follow-up appended.
     */
    suspend fun enqueueSync() {
        if (hasWaiting(SyncWork.SYNC)) return
        workManager.enqueueUniqueWork(SyncWork.SYNC, ExistingWorkPolicy.APPEND_OR_REPLACE, syncRequest(user = false))
    }

    /**
     * "Fetch new articles": sync → download as one continuation; any network (explicit user action).
     * Own unique name + REPLACE: it never queues behind a CONNECTED-constrained background sync (the
     * SyncEngine mutex serializes the actual work), so offline it fails fast.
     */
    fun enqueueFetch() {
        workManager
            .beginUniqueWork(SyncWork.FETCH, ExistingWorkPolicy.REPLACE, syncRequest(user = true))
            .then(downloadRequest(user = true, network = NetworkType.CONNECTED))
            .enqueue()
    }

    /**
     * Automatic download after a background sync; MANUAL policy enqueues nothing. A request made
     * while a download runs is chained after it (the follow-up re-queries the eligible items); one
     * that is already waiting will see the new items itself.
     */
    suspend fun enqueueAutoDownload() {
        val network = networkFor(preferences.userPreferences.first().downloadPolicy) ?: return
        if (hasWaiting(SyncWork.DOWNLOAD)) return
        workManager.enqueueUniqueWork(SyncWork.DOWNLOAD, ExistingWorkPolicy.APPEND_OR_REPLACE, downloadRequest(user = false, network = network))
    }

    /** Stops queued and running downloads (Settings > Remove downloads). */
    fun cancelDownloads() {
        workManager.cancelUniqueWork(SyncWork.DOWNLOAD)
        workManager.cancelAllWorkByTag(SyncWork.TAG_DOWNLOAD)
        workManager.cancelAllWorkByTag(SyncWork.TAG_ITEM_DOWNLOAD)
    }

    private suspend fun hasWaiting(uniqueName: String): Boolean =
        workManager.getWorkInfosForUniqueWorkFlow(uniqueName).first()
            .any { it.state == WorkInfo.State.ENQUEUED || it.state == WorkInfo.State.BLOCKED }

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
            .setConstraints(Constraints(requiredNetworkType = NetworkType.CONNECTED, requiresStorageNotLow = true))
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .addTag(SyncWork.TAG_ALL)
            .addTag(SyncWork.TAG_ITEM_DOWNLOAD)
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
            .setConstraints(Constraints(requiredNetworkType = network, requiresStorageNotLow = true))
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

/** Lets [app.sroka.core.data.content.ContentStoreImpl] stop queued downloads without knowing WorkManager. */
@Singleton
internal class WorkDownloadCanceller @Inject constructor(
    private val scheduler: WorkScheduler,
) : DownloadCanceller {
    override fun cancelDownloads() = scheduler.cancelDownloads()
}
