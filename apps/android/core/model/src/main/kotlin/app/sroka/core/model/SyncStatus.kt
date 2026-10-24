package app.sroka.core.model

/** Combined state of background sync and article downloads (DECISIONS A9). */
data class SyncStatus(
    val phase: SyncPhase = SyncPhase.Idle,
    /** Local changes not yet pushed to the server. */
    val pendingOps: Int = 0,
    /** Items whose article package is on the device. */
    val downloadedCount: Int = 0,
    /** Items eligible for offline reading (downloaded or still to download). */
    val availableCount: Int = 0,
    /** Epoch millis of the last successful sync, or null if never. */
    val lastSyncAt: Long? = null,
)

sealed interface SyncPhase {
    data object Idle : SyncPhase

    data object Syncing : SyncPhase

    /** Downloading article packages: [done] of [total], [currentTitle] being fetched. */
    data class Downloading(val done: Int, val total: Int, val currentTitle: String?) : SyncPhase

    /**
     * Full resync running (410 or a pass from cursor 0, DECISIONS A8.3). [fraction] 0..1, or null when
     * unknown (the pull response carries no total, api.md §7.2).
     */
    data class Resyncing(val fraction: Float? = null) : SyncPhase

    /** No network; the app shows saved articles. */
    data object Offline : SyncPhase

    data class Error(val kind: SyncErrorKind) : SyncPhase
}

enum class SyncErrorKind {
    /** Session expired (HTTP 401): the user must sign in again. */
    AUTH,
    NETWORK,
    SERVER,

    /** Not enough free device storage for article packages. */
    STORAGE,
}
