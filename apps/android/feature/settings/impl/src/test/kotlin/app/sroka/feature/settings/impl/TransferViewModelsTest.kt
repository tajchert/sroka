package app.sroka.feature.settings.impl

import app.sroka.core.domain.DataTransferRepository
import app.sroka.core.domain.ExportError
import app.sroka.core.domain.ExportResult
import app.sroka.core.domain.ImportError
import app.sroka.core.domain.ImportStartResult
import app.sroka.core.domain.PickedFile
import app.sroka.core.model.ExportFormat
import app.sroka.core.model.ImportFormat
import app.sroka.core.model.JobStatus
import app.sroka.core.testing.fake.FakeDataTransferRepository
import app.sroka.core.testing.fake.testImportJob
import app.sroka.core.testing.util.MainDispatcherRule
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class TransferViewModelsTest {
    @get:Rule val mainRule = MainDispatcherRule()

    private val repo = FakeDataTransferRepository()

    private fun importVm(): ImportViewModel {
        val vm = ImportViewModel(repo)
        // Keep the WhileSubscribed state flow hot for the test.
        vm.state.onEach { }.launchIn(kotlinx.coroutines.CoroutineScope(UnconfinedTestDispatcher()))
        return vm
    }

    @Test
    fun formatMappingByExtension() {
        assertEquals(ImportFormat.POCKET_CSV, resolveImportFormat(ImportSource.POCKET, "ril_export.CSV"))
        assertEquals(ImportFormat.POCKET_CSV, resolveImportFormat(ImportSource.POCKET, "pocket.zip"))
        assertEquals(ImportFormat.POCKET_HTML, resolveImportFormat(ImportSource.POCKET, "ril_export.html"))
        assertEquals(ImportFormat.POCKET_HTML, resolveImportFormat(ImportSource.POCKET, "x.HTM"))
        assertEquals(ImportFormat.INSTAPAPER_CSV, resolveImportFormat(ImportSource.INSTAPAPER, "a.html"))
        assertEquals(ImportFormat.NETSCAPE_HTML, resolveImportFormat(ImportSource.BROWSER, "bookmarks.html"))
    }

    @Test
    fun startImportUsesFormatFromPickedFile() = runTest {
        repo.files["content://f"] = PickedFile("export.html", 1_000)
        val vm = importVm()
        assertFalse(vm.state.value.canImport)
        vm.onFilePicked("content://f")
        assertTrue(vm.state.value.canImport)
        vm.startImport()
        assertEquals(listOf("content://f" to ImportFormat.POCKET_HTML), repo.startCalls)
        assertTrue(vm.state.value.jobRunning)
        assertFalse(vm.state.value.canImport)
    }

    @Test
    fun tooLargeIsCheckedBeforeUploading() = runTest {
        repo.files["content://big"] = PickedFile("big.csv", DataTransferRepository.MAX_IMPORT_BYTES + 1)
        val vm = importVm()
        vm.onFilePicked("content://big")
        vm.startImport()
        assertEquals(ImportError.TOO_LARGE, vm.state.value.error)
        assertTrue(repo.startCalls.isEmpty())
    }

    @Test
    fun startFailureSurfacesTypedError() = runTest {
        repo.files["content://f"] = PickedFile("a.csv", 10)
        repo.startResult = ImportStartResult.Failed(ImportError.RATE_LIMITED)
        val vm = importVm()
        vm.onFilePicked("content://f")
        vm.startImport()
        assertEquals(ImportError.RATE_LIMITED, vm.state.value.error)
        assertFalse(vm.state.value.uploading)
        assertTrue(vm.state.value.canImport)
    }

    @Test
    fun progressThenFinishedThenDismiss() = runTest {
        repo.files["content://f"] = PickedFile("a.csv", 10)
        val vm = importVm()
        vm.onFilePicked("content://f")
        vm.startImport()
        repo.setJob(testImportJob(status = JobStatus.RUNNING, total = 3180, done = 1204))
        assertEquals(1204, vm.state.value.job?.done)
        assertTrue(vm.state.value.jobRunning)
        repo.setJob(testImportJob(status = JobStatus.DONE, total = 10, done = 10, skipped = 2))
        assertFalse(vm.state.value.jobRunning)
        assertEquals(JobStatus.DONE, vm.state.value.job?.status)
        vm.dismiss()
        assertEquals(1, repo.dismissCount)
        assertNull(vm.state.value.job)
        assertFalse(vm.state.value.hasFile)
    }

    @Test
    fun exportSuccessAndFormatChange() = runTest {
        val vm = ExportViewModel(repo)
        assertEquals(ExportFormat.JSON, vm.state.value.format)
        vm.selectFormat(ExportFormat.CSV)
        vm.export()
        assertEquals(listOf(ExportFormat.CSV), repo.exportCalls)
        assertEquals("sroka-export.csv", vm.state.value.ready?.fileName)
        assertFalse(vm.state.value.exporting)
        vm.selectFormat(ExportFormat.JSON)
        assertNull(vm.state.value.ready)
    }

    @Test
    fun exportFailureShowsTypedError() = runTest {
        repo.exportResult = ExportResult.Failed(ExportError.NETWORK)
        val vm = ExportViewModel(repo)
        vm.export()
        assertEquals(ExportError.NETWORK, vm.state.value.error)
        assertNull(vm.state.value.ready)
        assertNotNull(vm.state.value.format)
    }

    @Test
    fun deleteConfirmation() {
        assertFalse(isDeleteConfirmed("", "me@x.io"))
        assertFalse(isDeleteConfirmed("me@x", "me@x.io"))
        assertTrue(isDeleteConfirmed("  ME@X.io ", "me@x.io"))
        assertFalse(isDeleteConfirmed("anything", null))
        assertFalse(isDeleteConfirmed("", ""))
    }
}
