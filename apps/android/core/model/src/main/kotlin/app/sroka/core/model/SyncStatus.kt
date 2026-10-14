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

    /** No network; the app shows saved articles. */
    data object Offline : SyncPhase

    data class Error(val kind: SyncErrorKind) : SyncPhase
}

enum class SyncErrorKind {
    /** Session expired (HTTP 401): the user must sign in again. */
    AUTH,
    NETWORK,
    SERVER,
}
