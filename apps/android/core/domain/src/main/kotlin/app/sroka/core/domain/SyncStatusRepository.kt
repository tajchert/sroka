package app.sroka.core.domain

import app.sroka.core.model.SyncErrorKind
import app.sroka.core.model.SyncStatus
import kotlinx.coroutines.flow.Flow

/** Observable state of sync + downloads for progress UI (DECISIONS A9, A11). */
interface SyncStatusRepository {

    /** Current phase and counts; emits immediately. */
    val status: Flow<SyncStatus>

    /** One-shot results of user-initiated fetches (hot; not replayed to late collectors). */
    val events: Flow<SyncEvent>
}

sealed interface SyncEvent {
    /** A fetch finished. [newlyDownloaded] == 0 means "Library is up to date". */
    data class FetchCompleted(val newlyDownloaded: Int) : SyncEvent

    /** A fetch stopped early. */
    data class FetchFailed(val kind: SyncErrorKind) : SyncEvent
}
