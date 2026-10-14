package app.sroka.core.testing.fake

import app.sroka.core.domain.ContentStore
import app.sroka.core.domain.DownloadResult
import app.sroka.core.model.OfflineState
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import java.io.File

/** In-memory [ContentStore]: [html] by item id, [offline] states, scripted [nextDownloadResult]. */
class FakeContentStore(
    private val articlesDir: File = File("build/fake-articles"),
) : ContentStore {

    val html = MutableStateFlow<Map<String, String>>(emptyMap())
    val offline = MutableStateFlow<Map<String, OfflineState>>(emptyMap())
    var usageBytes: Long = 0
    var nextDownloadResult: DownloadResult = DownloadResult.Downloaded
    val downloadRequests = mutableListOf<String>()

    override fun observeOffline(itemId: String): Flow<OfflineState> =
        offline.map { it[itemId] ?: OfflineState.NONE }

    override suspend fun articleHtml(itemId: String): String? = html.value[itemId]

    override fun articlesDirectory(): File = articlesDir

    override suspend fun downloadNow(itemId: String): DownloadResult {
        downloadRequests += itemId
        val result = nextDownloadResult
        if (result == DownloadResult.Downloaded) {
            offline.update { it + (itemId to OfflineState.DOWNLOADED) }
            html.update { if (itemId in it) it else it + (itemId to "<p>Article $itemId</p>") }
        }
        return result
    }

    override suspend fun storageUsageBytes(): Long = usageBytes

    override suspend fun clearDownloads() {
        html.value = emptyMap()
        offline.update { map -> map.mapValues { OfflineState.AVAILABLE_REMOTE } }
        usageBytes = 0
    }
}
