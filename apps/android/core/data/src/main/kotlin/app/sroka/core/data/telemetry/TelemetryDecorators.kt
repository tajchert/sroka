package app.sroka.core.data.telemetry

import android.net.Uri
import app.sroka.core.domain.DataTransferRepository
import app.sroka.core.domain.ExportResult
import app.sroka.core.domain.ImportStartResult
import app.sroka.core.domain.LibraryRepository
import app.sroka.core.domain.PdfUploader
import app.sroka.core.domain.SaveSource
import app.sroka.core.domain.Telemetry
import app.sroka.core.domain.TelemetryEvent
import app.sroka.core.domain.TelemetrySource
import app.sroka.core.model.ExportFormat
import app.sroka.core.model.ImportFormat
import app.sroka.core.model.ItemKind
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.PdfUpload
import app.sroka.core.model.PdfUploadState
import app.sroka.core.model.SaveResult
import kotlinx.coroutines.flow.firstOrNull

// Repository decorators that report D15 events. Only enums leave this file: never ids, URLs,
// titles, tag names or file names.

/** Reports save_item, archive/unarchive, favorite, delete and add_tag for user-initiated changes. */
internal class TelemetryLibraryRepository(
    private val delegate: LibraryRepository,
    private val telemetry: Telemetry,
) : LibraryRepository by delegate {

    override suspend fun save(url: String, title: String?, tags: List<String>, source: SaveSource): SaveResult {
        val result = delegate.save(url, title, tags, source)
        if (result is SaveResult.Saved && !result.alreadySaved) {
            val origin = when (source) {
                SaveSource.SHARE -> TelemetrySource.SHARE
                SaveSource.MANUAL -> TelemetrySource.WEB_ADD
                SaveSource.DRAG -> TelemetrySource.DRAG
            }
            telemetry.logEvent(TelemetryEvent.SaveItem(origin, ItemKind.ARTICLE))
        }
        return result
    }

    override suspend fun setStatus(id: String, status: ItemStatus) {
        delegate.setStatus(id, status)
        telemetry.logEvent(
            if (status == ItemStatus.ARCHIVED) TelemetryEvent.ArchiveItem else TelemetryEvent.UnarchiveItem,
        )
    }

    override suspend fun setFavorite(id: String, favorite: Boolean) {
        delegate.setFavorite(id, favorite)
        telemetry.logEvent(TelemetryEvent.FavoriteItem(favorite))
    }

    override suspend fun delete(id: String) {
        delegate.delete(id)
        telemetry.logEvent(TelemetryEvent.DeleteItem)
    }

    override suspend fun setTags(id: String, names: List<String>) {
        val before = delegate.observeItem(id).firstOrNull()?.tags.orEmpty()
        delegate.setTags(id, names)
        if (names.any { it !in before }) telemetry.logEvent(TelemetryEvent.AddTag)
    }
}

/** Reports save_item {pdf} for each PDF accepted for upload. */
internal class TelemetryPdfUploader(
    private val delegate: PdfUploader,
    private val telemetry: Telemetry,
) : PdfUploader by delegate {

    override suspend fun enqueue(uris: List<Uri>): List<PdfUpload> {
        val uploads = delegate.enqueue(uris)
        uploads.filter { it.state !is PdfUploadState.Failed }.forEach { _ ->
            telemetry.logEvent(TelemetryEvent.SaveItem(TelemetrySource.PDF, ItemKind.PDF))
        }
        return uploads
    }
}

/** Reports import_start and export. */
internal class TelemetryDataTransferRepository(
    private val delegate: DataTransferRepository,
    private val telemetry: Telemetry,
) : DataTransferRepository by delegate {

    override suspend fun startImport(uri: String, format: ImportFormat): ImportStartResult {
        val result = delegate.startImport(uri, format)
        if (result is ImportStartResult.Started) telemetry.logEvent(TelemetryEvent.ImportStart())
        return result
    }

    override suspend fun export(format: ExportFormat): ExportResult {
        val result = delegate.export(format)
        if (result is ExportResult.Ready) telemetry.logEvent(TelemetryEvent.Export(format))
        return result
    }
}
