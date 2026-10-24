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

    /**
     * The downloaded original of a `kind == PDF` item (`articles/{itemId}/document.pdf`), or null if
     * it is not (or no longer) on disk. Never touches the network.
     */
    suspend fun pdfFile(itemId: String): File?

    /**
     * Local file for a PDF item, downloading `documentUrl` first when needed (same offline policy
     * and storage as article packages; the signed URL is re-fetched when it expired).
     */
    suspend fun ensurePdfFile(itemId: String): PdfFileResult {
        pdfFile(itemId)?.let { return PdfFileResult.Ready(it) }
        return when (val r = downloadNow(itemId)) {
            DownloadResult.Downloaded ->
                pdfFile(itemId)?.let { PdfFileResult.Ready(it) } ?: PdfFileResult.Failed(RemoteFailure.SERVER)
            DownloadResult.NotReady -> PdfFileResult.NotReady
            is DownloadResult.Failed -> PdfFileResult.Failed(r.reason)
        }
    }

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

sealed interface PdfFileResult {
    data class Ready(val file: File) : PdfFileResult

    /** The server has no document for this item (yet). */
    data object NotReady : PdfFileResult

    data class Failed(val reason: RemoteFailure) : PdfFileResult
}
