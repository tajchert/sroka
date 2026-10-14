package app.sroka.feature.library.impl

import app.cash.turbine.test
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.SessionState
import app.sroka.core.testing.fake.FakeAuthRepository
import app.sroka.core.testing.fake.FakeLibraryRepository
import app.sroka.core.testing.fake.FakeSettingsRepository
import app.sroka.core.testing.fake.FakeSyncController
import app.sroka.core.testing.fake.FakeSyncStatusRepository
import app.sroka.core.testing.fake.FakeTagRepository
import app.sroka.core.testing.testItem
import app.sroka.core.testing.util.MainDispatcherRule
import app.sroka.feature.library.impl.list.LibraryListViewModel
import app.sroka.feature.library.impl.list.ListEvent
import app.sroka.feature.library.impl.save.SaveSheetViewModel
import app.sroka.feature.library.impl.save.SaveState
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class LibraryViewModelsTest {

    @get:Rule
    val main = MainDispatcherRule()

    private val library = FakeLibraryRepository()

    private fun listVm() = LibraryListViewModel(
        library, FakeTagRepository(), FakeSyncController(), FakeSyncStatusRepository(),
        FakeAuthRepository(SessionState.SignedIn("a@b.c")), FakeSettingsRepository(),
    )

    @Test
    fun addLinkExtractsUrlFromPastedText() = runTest {
        val vm = listVm()
        assertTrue(vm.addLink("look https://example.com/post?utm_source=x now"))
        assertEquals(1, library.items.value.size)
        assertEquals("web", library.items.value.single().source)
    }

    @Test
    fun addLinkRejectsGarbage() = runTest {
        assertFalse(listVm().addLink("not a url"))
        assertTrue(library.items.value.isEmpty())
    }

    @Test
    fun toggleArchiveEmitsUndoEvent() = runTest {
        library.items.value = listOf(testItem(id = "a"))
        val vm = listVm()
        vm.events.test {
            vm.toggleArchive("a", ItemStatus.UNREAD)
            assertTrue(awaitItem() is ListEvent.Undoable)
            assertEquals(ItemStatus.ARCHIVED, library.items.value.single().status)
        }
    }

    @Test
    fun shareSavesOnceAndUsesSubjectAsTitle() = runTest {
        val vm = SaveSheetViewModel(library, FakeTagRepository(), FakeAuthRepository(SessionState.SignedIn("a@b.c")))
        vm.start("Read https://example.com/a", "Nice title")
        vm.start("Read https://example.com/a", "Nice title")
        assertTrue(vm.state.first() is SaveState.Saved)
        assertEquals("Nice title", library.items.value.single().title)
    }

    @Test
    fun shareWithoutUrlOrSession() = runTest {
        val noUrl = SaveSheetViewModel(library, FakeTagRepository(), FakeAuthRepository(SessionState.SignedIn("a@b.c")))
        noUrl.start("no link here", null)
        assertEquals(SaveState.NoUrl, noUrl.state.value)

        val signedOut = SaveSheetViewModel(library, FakeTagRepository(), FakeAuthRepository(SessionState.SignedOut))
        signedOut.start("https://example.com", null)
        assertEquals(SaveState.NeedsSignIn, signedOut.state.value)
        assertEquals(0, library.items.value.size)
    }
}
