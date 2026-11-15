package app.sroka.feature.library.impl

import app.cash.turbine.test
import app.sroka.core.domain.ConnectedClients
import app.sroka.core.model.ItemQuery
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.SessionState
import app.sroka.core.model.SortOrder
import app.sroka.core.model.TagCount
import app.sroka.core.testing.fake.FakeAccountRepository
import app.sroka.core.testing.fake.FakeAuthRepository
import app.sroka.core.testing.fake.FakeLibraryRepository
import app.sroka.core.testing.fake.FakePdfUploader
import app.sroka.core.testing.fake.FakeSettingsRepository
import app.sroka.core.testing.fake.FakeSyncController
import app.sroka.core.testing.fake.FakeSyncStatusRepository
import app.sroka.core.testing.fake.FakeTagRepository
import app.sroka.core.testing.util.MainDispatcherRule
import app.sroka.feature.library.impl.list.LibraryListViewModel
import app.sroka.feature.library.impl.list.ListFilters
import app.sroka.feature.library.impl.list.ListScope
import app.sroka.feature.library.impl.list.listQuery
import app.sroka.feature.library.impl.list.showsOnboarding
import app.sroka.feature.library.impl.list.tagChips
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** Home chip row (proposal 08) and onboarding (proposal 01) logic. */
class HomeFiltersTest {

    @get:Rule
    val main = MainDispatcherRule()

    private val tags = FakeTagRepository()
    private val account = FakeAccountRepository()

    private fun vm() = LibraryListViewModel(
        FakeLibraryRepository(), tags, account, FakeSyncController(), FakeSyncStatusRepository(),
        FakeAuthRepository(SessionState.SignedIn("a@b.c")), FakeSettingsRepository(), FakePdfUploader(),
    )

    @Test fun filtersMapToTheQueryWithinTheTab() {
        val all = ListFilters(favoritesOnly = true, underTenMinutes = true, tag = "rust")
        assertEquals(
            ItemQuery(LibraryTab.ARCHIVE, tag = "rust", sort = SortOrder.OLDEST, favoritesOnly = true, maxReadingMinutes = 9),
            listQuery(ListScope.Tab(LibraryTab.ARCHIVE), all, SortOrder.OLDEST),
        )
        assertEquals(ItemQuery(LibraryTab.MY_LIST), listQuery(ListScope.Tab(LibraryTab.MY_LIST), ListFilters(), SortOrder.NEWEST))
        // A tag page lists every live item with the tag; home filters don't apply.
        assertEquals(ItemQuery(tab = null, tag = "rust"), listQuery(ListScope.Tag("rust"), all, SortOrder.NEWEST))
    }

    @Test fun activeMeansAnyFilter() {
        assertFalse(ListFilters().active)
        assertTrue(ListFilters(favoritesOnly = true).active)
        assertTrue(ListFilters(underTenMinutes = true).active)
        assertTrue(ListFilters(tag = "x").active)
    }

    @Test fun selectedTagChipComesFirstWithoutDuplicates() {
        assertEquals(listOf("a", "b"), tagChips(listOf("a", "b"), null))
        assertEquals(listOf("B", "a", "c"), tagChips(listOf("a", "b", "c"), "B"))
        assertEquals(listOf("z", "a"), tagChips(listOf("a"), "z"))
    }

    @Test fun onboardingOnlyOnEmptyUnfilteredMyList() {
        val myList = ListScope.Tab(LibraryTab.MY_LIST)
        assertTrue(showsOnboarding(myList, ListFilters(), isEmpty = true))
        assertFalse(showsOnboarding(myList, ListFilters(), isEmpty = false))
        assertFalse(showsOnboarding(myList, ListFilters(favoritesOnly = true), isEmpty = true))
        assertFalse(showsOnboarding(ListScope.Tab(LibraryTab.ARCHIVE), ListFilters(), isEmpty = true))
        assertFalse(showsOnboarding(ListScope.Tag("x"), ListFilters(), isEmpty = true))
    }

    @Test fun topTagsAreTheFiveMostUsed() = runTest {
        tags.tags.value = listOf(
            TagCount("a", 1), TagCount("b", 9), TagCount("c", 5), TagCount("d", 0),
            TagCount("e", 7), TagCount("f", 3), TagCount("g", 2),
        )
        vm().topTags.test {
            var value = awaitItem()
            if (value.isEmpty()) value = awaitItem()
            assertEquals(listOf("b", "e", "c", "f", "g"), value)
        }
    }

    @Test fun extensionStepFollowsConnectedClientsAndFailuresAreSilent() = runTest {
        val vm = vm()
        account.clients = null // request failed
        vm.refreshConnectedClients()
        assertFalse(vm.extensionConnected.value)
        account.clients = ConnectedClients(extension = false)
        vm.refreshConnectedClients()
        assertFalse(vm.extensionConnected.value)
        account.clients = ConnectedClients(extension = true)
        vm.refreshConnectedClients()
        assertTrue(vm.extensionConnected.value)
        // Sticky once done: no more requests.
        val calls = account.clientsCalls
        vm.refreshConnectedClients()
        assertEquals(calls, account.clientsCalls)
    }
}
