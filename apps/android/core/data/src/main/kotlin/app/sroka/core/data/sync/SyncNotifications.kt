package app.sroka.core.data.sync

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.ForegroundInfo
import app.sroka.core.data.R

/** Low-importance `downloads` channel and the progress notification (DECISIONS A9). */
object SyncNotifications {
    const val CHANNEL_ID = "downloads"
    const val NOTIFICATION_ID = 0x5120

    /** Idempotent; the app may call it at startup, workers call it lazily. */
    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.sync_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = context.getString(R.string.sync_channel_description)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    fun syncing(context: Context): ForegroundInfo =
        foregroundInfo(build(context, context.getString(R.string.sync_notification_syncing), 0, 0))

    fun downloading(context: Context, done: Int, total: Int): ForegroundInfo {
        val text = if (total == 0) {
            context.getString(R.string.sync_notification_preparing)
        } else {
            context.getString(R.string.sync_notification_downloading, done, total)
        }
        return foregroundInfo(build(context, text, done, total))
    }

    private fun build(context: Context, text: String, done: Int, total: Int): Notification {
        ensureChannel(context)
        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_sroka)
            .setContentTitle(text)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setProgress(total, done, total == 0)
            .apply {
                context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { intent ->
                    setContentIntent(
                        PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
                    )
                }
            }
            .build()
    }

    private fun foregroundInfo(notification: Notification): ForegroundInfo =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(NOTIFICATION_ID, notification)
        }
}
