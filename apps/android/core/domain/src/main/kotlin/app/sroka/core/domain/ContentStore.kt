package app.sroka.core.domain

import app.sroka.core.model.OfflineState
import kotlinx.coroutines.flow.Flow
import java.io.File

/**
 * Reader-facing part of offline article storage (DECISIONS A9/A10). Packages live in
 * `filesDir/articles/{itemId}/` (`article.html`, `img/…`) and are served to the WebView through
 * WebViewAssetLoader at [ARTICLE_ASSET_BASE_URL].
 */
interface ContentStore {

    /** Offline state of one item's article package. */
    fun observeOffline(itemId: String): Flow<OfflineState>

    /** The downloaded `article.html`, or null if not downloaded. */
    suspend fun articleHtml(itemId: String): String?

    /** Base URL for `loadDataWithBaseURL`: `"$ARTICLE_ASSET_BASE_URL$itemId/"`. */
    fun articleBaseUrl(itemId: String): String = "$ARTICLE_ASSET_BASE_URL$itemId/"

    /** Root directory of unpacked packages (`filesDir/articles`), for the asset loader path handler. */
    fun articlesDirectory(): File

    /** Downloads this item's package now (reader "not downloaded yet" path). */
    suspend fun downloadNow(itemId: String): DownloadResult

    /** Bytes used by article packages and thumbnails. */
    suspend fun storageUsageBytes(): Long

    /** Deletes every downloaded package; items become AVAILABLE_REMOTE. */
    suspend fun clearDownloads()

    companion object {
        /** WebViewAssetLoader origin + path that maps to [articlesDirectory]. */
        const val ARTICLE_ASSET_BASE_URL = "https://appassets.androidplatform.net/articles/"
    }
}

sealed interface DownloadResult {
    data object Downloaded : DownloadResult

    /** The server has not finished parsing the article yet (HTTP 409 `not_parsed`). */
    data object NotReady : DownloadResult

    data class Failed(val reason: RemoteFailure) : DownloadResult
}
