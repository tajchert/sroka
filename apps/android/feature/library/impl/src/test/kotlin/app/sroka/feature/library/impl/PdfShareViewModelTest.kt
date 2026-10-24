package app.sroka.feature.library.impl

import android.net.Uri
import app.sroka.core.model.SessionState
import app.sroka.core.testing.fake.FakeAuthRepository
import app.sroka.core.testing.fake.FakePdfUploader
import app.sroka.core.testing.util.MainDispatcherRule
import app.sroka.feature.library.impl.save.PdfShareState
import app.sroka.feature.library.impl.save.PdfShareViewModel
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class PdfShareViewModelTest {
    @get:Rule
    val main = MainDispatcherRule()

    private val uploader = FakePdfUploader()
    private fun vm() = PdfShareViewModel(uploader, FakeAuthRepository(SessionState.SignedIn("a@b.c")))
    private val uri = Uri.parse("content://x/1")

    @Test
    fun duplicateAnswerReplacesQueued() = runTest {
        val vm = vm()
        vm.start(listOf(uri))
        assertEquals(PdfShareState.Queued(1), vm.state.value)
        uploader.complete("upload-1", duplicate = true)
        assertEquals(PdfShareState.Duplicate(1), vm.state.value)
    }

    @Test
    fun newFileEndsAsSaved() = runTest {
        val vm = vm()
        vm.start(listOf(uri))
        uploader.complete("upload-1", duplicate = false)
        assertEquals(PdfShareState.Saved(1), vm.state.value)
    }
}
