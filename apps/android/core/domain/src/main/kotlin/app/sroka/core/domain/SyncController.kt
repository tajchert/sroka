package app.sroka.core.domain

/**
 * Starts background work (WorkManager, DECISIONS A8/A9). All calls are fire-and-forget and safe to
 * call repeatedly; progress and results are observed through [SyncStatusRepository].
 */
interface SyncController {

    /** Background sync (push + pull), e.g. on app foreground. Honors the download policy afterwards. */
    fun requestSync()

    /**
     * User-initiated "Fetch new articles" / pull-to-refresh: sync, then download all eligible
     * articles, ignoring the Wi-Fi-only policy (explicit action). Completion is reported as a
     * [SyncEvent] on [SyncStatusRepository.events].
     */
    fun fetchNewArticles()

    /** Queues a download of one item's article package with high priority (any network). */
    fun downloadItemNow(itemId: String)
}
