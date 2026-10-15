package app.sroka.core.testing.fake

import app.sroka.core.domain.SyncController
import app.sroka.core.domain.SyncEvent
import app.sroka.core.domain.SyncStatusRepository
import app.sroka.core.model.SyncStatus
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow

/** Records calls to the [SyncController] methods. */
class FakeSyncController : SyncController {
    var syncRequests = 0
        private set
    var fetchRequests = 0
        private set
    val downloadNowRequests = mutableListOf<String>()

    override fun requestSync() {
        syncRequests++
    }

    override fun fetchNewArticles() {
        fetchRequests++
    }

    override fun downloadItemNow(itemId: String) {
        downloadNowRequests += itemId
    }
}

/** Drive [statusFlow] and [emit] events from the test. */
class FakeSyncStatusRepository(initial: SyncStatus = SyncStatus()) : SyncStatusRepository {
    val statusFlow = MutableStateFlow(initial)
    private val eventFlow = MutableSharedFlow<SyncEvent>(extraBufferCapacity = 16)

    override val status: Flow<SyncStatus> = statusFlow
    override val events: Flow<SyncEvent> = eventFlow

    suspend fun emit(event: SyncEvent) = eventFlow.emit(event)
}
