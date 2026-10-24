package app.sroka.feature.library.impl

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.test.swipeLeft
import app.sroka.core.model.OfflineState
import app.sroka.core.designsystem.theme.SrokaTheme
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.SessionState
import app.sroka.core.model.SyncPhase
import app.sroka.core.model.SyncStatus
import app.sroka.core.testing.fake.FakeAuthRepository
import app.sroka.core.testing.fake.FakeLibraryRepository
import app.sroka.core.testing.fake.FakeSettingsRepository
import app.sroka.core.testing.fake.FakeSyncController
import app.sroka.core.testing.fake.FakeSyncStatusRepository
import app.sroka.core.testing.fake.FakeTagRepository
import app.sroka.core.testing.testItem
import app.sroka.feature.library.impl.list.LibraryListRoute
import app.sroka.feature.library.impl.list.LibraryListViewModel
import app.sroka.feature.library.impl.list.ListScope
import androidx.paging.LoadState
import androidx.paging.LoadStates
import androidx.paging.PagingData
import app.sroka.core.domain.LibraryRepository
import app.sroka.core.model.Item
import app.sroka.core.model.ItemQuery
import app.sroka.core.model.ItemSummary
import app.sroka.core.model.toSummary
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
class LibraryListScreenTest {

    @get:Rule
    val compose = createComposeRule()

    private val fake = FakeLibraryRepository()
    private val library = fake
    private val sync = FakeSyncController()
    private val status = FakeSyncStatusRepository()
    private val auth = FakeAuthRepository(SessionState.SignedIn("a@b.c"))
    private val opened = mutableListOf<String>()
    private var signInClicks = 0
    private var settingsClicks = 0
    private val searchOpened = mutableListOf<LibraryTab>()

    private fun show(scope: ListScope = ListScope.Tab(LibraryTab.MY_LIST)) {
        val vm = LibraryListViewModel(LoadedLibrary(fake), FakeTagRepository(), sync, status, auth, FakeSettingsRepository())
        compose.setContent {
            SrokaTheme(dynamicColor = false) {
                LibraryListRoute(
                    scope = scope,
                    onOpenItem = { opened += it },
                    onSignIn = { signInClicks++ },
                    onOpenSettings = { settingsClicks++ },
                    onOpenSearch = { searchOpened += it },
                    viewModel = vm,
                )
            }
        }
    }

    @Test
    fun emptyListShowsGuidance() {
        show()
        compose.waitUntil(5_000) { compose.onAllNodesMatching("Share any link to Sroka to save it") }
        compose.onNodeWithText("Share any link to Sroka to save it").assertIsDisplayed()
    }

    @Test
    fun tappingRowOpensItem() {
        fake.items.value = listOf(testItem(id = "a", title = "Alpha"), testItem(id = "b", title = "Beta"))
        show()
        compose.waitUntil(5_000) { compose.onAllNodesMatching("Beta") }
        compose.onNodeWithText("Beta").performClick()
        assertEquals(listOf("b"), opened)
    }

    @Test
    fun swipeArchivesAndUndoRestores() {
        fake.items.value = listOf(testItem(id = "a", title = "Alpha"))
        show()
        compose.waitUntil(5_000) { compose.onAllNodesMatching("Alpha") }
        compose.onNodeWithText("Alpha").performTouchInput { swipeLeft() }
        compose.waitUntil(5_000) { fake.items.value.single().status == ItemStatus.ARCHIVED }
        compose.waitUntil(5_000) { compose.onAllNodesMatching("Undo") }
        compose.onNodeWithText("Undo").performClick()
        compose.waitUntil(5_000) { fake.items.value.single().status == ItemStatus.UNREAD }
    }

    @Test
    fun pullToRefreshTriggersController() {
        fake.items.value = listOf(testItem(id = "a", title = "Alpha"))
        show()
        compose.waitUntil(5_000) { compose.onAllNodesMatching("Alpha") }
        compose.onNodeWithText("Alpha").performTouchInput { swipeDown(startY = top, endY = bottom + 600f) }
        compose.waitUntil(5_000) { sync.fetchRequests == 1 }
    }

    @Test
    fun searchBarShowsHintAndAvatarOpensSettings() {
        show()
        compose.onNodeWithText("Search My List").assertIsDisplayed()
        compose.onNodeWithText("A").assertIsDisplayed()
        compose.onNodeWithText("A").performClick()
        assertEquals(1, settingsClicks)
    }

    @Test
    fun searchBarOpensSearch() {
        show()
        compose.onNodeWithText("Search My List").performClick()
        assertEquals(listOf(LibraryTab.MY_LIST), searchOpened)
    }

    @Test
    fun rowsShowStatusLineAndFavouriteStar() {
        fake.items.value = listOf(
            testItem(id = "a", title = "Alpha", offline = OfflineState.DOWNLOADED, isFavorite = true),
        )
        show()
        compose.waitUntil(5_000) { compose.onAllNodesMatching("Available offline") }
        compose.onNodeWithContentDescription("Favourite").assertIsDisplayed()
    }

    @Test
    fun downloadingProgressText() {
        status.statusFlow.value = SyncStatus(phase = SyncPhase.Downloading(3, 12, null))
        show()
        compose.waitUntil(5_000) { compose.onAllNodesMatching("3 of 12") }
        compose.onNodeWithText("3 of 12").assertIsDisplayed()
    }

    @Test
    fun offlineAndSignInBanners() {
        status.statusFlow.value = SyncStatus(phase = SyncPhase.Offline, pendingOps = 3)
        auth.sessionFlow.value = SessionState.Expired("a@b.c")
        show()
        compose.waitUntil(5_000) { compose.onAllNodesMatching("Sign in again to sync") }
        compose.onNodeWithText("Sign in").performClick()
        assertEquals(1, signInClicks)
    }

    private fun androidx.compose.ui.test.junit4.ComposeContentTestRule.onAllNodesMatching(text: String): Boolean =
        onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()
}

/**
 * [FakeLibraryRepository.pagedItems] emits `PagingData.from(list)` without load states, which leaves
 * `refresh` at Loading forever; real Room paging reports NotLoading. This wrapper reports it.
 */
private class LoadedLibrary(private val fake: FakeLibraryRepository) : LibraryRepository by fake {
    override fun pagedItems(query: ItemQuery): Flow<PagingData<ItemSummary>> = fake.items.map { all ->
        val done = LoadState.NotLoading(endOfPaginationReached = true)
        PagingData.from(
            fake.filter(all, query).map(Item::toSummary),
            sourceLoadStates = LoadStates(refresh = done, prepend = done, append = done),
        )
    }
}
