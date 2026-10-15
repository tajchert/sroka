package app.sroka.core.data.sync

import app.sroka.core.domain.SyncEvent
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import javax.inject.Inject
import javax.inject.Singleton

/** Results of user-initiated fetches, emitted by the workers (same process). Hot, not replayed. */
@Singleton
class SyncEventBus @Inject constructor() {
    private val flow = MutableSharedFlow<SyncEvent>(extraBufferCapacity = 8)

    val events: SharedFlow<SyncEvent> = flow.asSharedFlow()

    fun emit(event: SyncEvent) {
        flow.tryEmit(event)
    }
}
