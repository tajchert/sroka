package app.sroka.core.data.transfer

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.ForegroundInfo
import app.sroka.core.data.R
import app.sroka.core.model.ImportJob
import app.sroka.core.model.JobStatus

/** "Imports" channel, the ongoing progress notification and the final result notification (RULINGS R11). */
object ImportNotifications {
    const val CHANNEL_ID = "imports"
    const val PROGRESS_ID = 0x5130
    const val RESULT_ID = 0x5131

    // Copy of core:designsystem's ic_stat_sroka (core:data does not depend on it).
    private val SMALL_ICON = R.drawable.ic_stat_sroka

    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.import_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = context.getString(R.string.import_channel_description)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    fun foregroundInfo(context: Context, job: ImportJob?): ForegroundInfo {
        val notification = progress(context, job)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(PROGRESS_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(PROGRESS_ID, notification)
        }
    }

    /** Updates the ongoing notification; silently does nothing without POST_NOTIFICATIONS. */
    fun updateProgress(context: Context, job: ImportJob) = notify(context, PROGRESS_ID, progress(context, job))

    /** Replaces the progress notification with the final "finished"/"failed" one. */
    fun showResult(context: Context, job: ImportJob) {
        val failed = job.status == JobStatus.FAILED
        val title = if (failed) {
            context.getString(R.string.import_notification_failed)
        } else {
            val count = (job.done - job.skipped).coerceAtLeast(0)
            context.resources.getQuantityString(R.plurals.import_notification_finished, count, count)
        }
        ensureChannel(context)
        val notification = base(context, title)
            .setOngoing(false)
            .setAutoCancel(true)
            .build()
        notify(context, RESULT_ID, notification)
    }

    fun cancelProgress(context: Context) = NotificationManagerCompat.from(context).cancel(PROGRESS_ID)

    private fun progress(context: Context, job: ImportJob?): Notification {
        ensureChannel(context)
        val total = job?.total
        val builder = base(context, context.getString(R.string.import_notification_title)).setOngoing(true)
        when {
            job == null -> builder.setProgress(0, 0, true)
            total != null && total > 0 -> builder
                .setContentText(context.getString(R.string.import_notification_progress, job.done, total))
                .setProgress(total, job.done.coerceAtMost(total), false)
            else -> builder
                .setContentText(context.getString(R.string.import_notification_waiting))
                .setProgress(0, 0, true)
        }
        return builder.build()
    }

    private fun base(context: Context, title: String): NotificationCompat.Builder =
        NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(SMALL_ICON)
            .setContentTitle(title)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .apply {
                context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { intent ->
                    setContentIntent(
                        PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
                    )
                }
            }

    @SuppressLint("MissingPermission")
    private fun notify(context: Context, id: Int, notification: Notification) {
        val granted = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        if (!granted) return
        runCatching { NotificationManagerCompat.from(context).notify(id, notification) }
    }
}
