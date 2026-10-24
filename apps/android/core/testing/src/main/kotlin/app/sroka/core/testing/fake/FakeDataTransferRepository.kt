package app.sroka.core.testing.fake

import app.sroka.core.domain.DataTransferRepository
import app.sroka.core.domain.ExportResult
import app.sroka.core.domain.ImportStartResult
import app.sroka.core.domain.PickedFile
import app.sroka.core.model.ExportFormat
import app.sroka.core.model.ImportFormat
import app.sroka.core.model.ImportJob
import app.sroka.core.model.JobStatus
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow

/** Scripted [DataTransferRepository]. Set [startResult]/[exportResult]/[files]; drive progress with [setJob]. */
class FakeDataTransferRepository : DataTransferRepository {
    private val active = MutableStateFlow<ImportJob?>(null)

    var startResult: ImportStartResult = ImportStartResult.Started(testImportJob())
    var exportResult: ExportResult = ExportResult.Ready("/cache/exports/sroka-export.csv", "sroka-export.csv", 48_000)
    var files: MutableMap<String, PickedFile> = mutableMapOf()

    val startCalls = mutableListOf<Pair<String, ImportFormat>>()
    val exportCalls = mutableListOf<ExportFormat>()
    var dismissCount = 0
        private set

    /** Emulates the progress worker updating the stored job. */
    fun setJob(job: ImportJob?) {
        active.value = job
    }

    override suspend fun startImport(uri: String, format: ImportFormat): ImportStartResult {
        startCalls += uri to format
        (startResult as? ImportStartResult.Started)?.let { active.value = it.job }
        return startResult
    }

    override fun activeImport(): Flow<ImportJob?> = active

    val resumed = mutableListOf<String>()

    override fun resumeTracking(jobId: String) {
        resumed += jobId
    }

    override suspend fun dismissImport() {
        dismissCount++
        active.value = null
    }

    override suspend fun export(format: ExportFormat): ExportResult {
        exportCalls += format
        return exportResult
    }

    override fun fileInfo(uri: String): PickedFile? = files[uri]
}

fun testImportJob(
    id: String = "job1",
    status: JobStatus = JobStatus.QUEUED,
    format: ImportFormat = ImportFormat.POCKET_CSV,
    total: Int? = null,
    done: Int = 0,
    skipped: Int = 0,
    error: String? = null,
) = ImportJob(id, status, format, total, done, skipped, error, createdAt = 1_000, updatedAt = 1_000)
