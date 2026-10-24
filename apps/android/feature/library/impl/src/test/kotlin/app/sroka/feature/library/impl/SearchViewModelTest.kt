package app.sroka.feature.library.impl

import app.sroka.core.model.LibraryTab
import app.sroka.core.model.SearchScope
import app.sroka.core.testing.fake.FakeLibraryRepository
import app.sroka.core.testing.testItem
import app.sroka.core.testing.util.MainDispatcherRule
import app.sroka.feature.library.impl.search.SearchViewModel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SearchViewModelTest {
    @get:Rule
    val main = MainDispatcherRule()

    private val library = FakeLibraryRepository().apply { items.value = listOf(testItem(id = "a", title = "Fire escape")) }

    @Test
    fun queryIsDebouncedAndBlankDoesNotSearch() = runTest {
        val vm = SearchViewModel(library)
        backgroundScope.launch { vm.results.collect {} }
        runCurrent()
        assertNull(library.lastSearch)

        vm.onQueryChange("fi")
        advanceTimeBy(100)
        runCurrent()
        assertNull(library.lastSearch)
        vm.onQueryChange("fire")
        advanceTimeBy(200)
        runCurrent()
        assertNull(library.lastSearch)
        advanceTimeBy(100)
        runCurrent()
        assertEquals("fire" to SearchScope.ALL, library.lastSearch)
    }

    @Test
    fun scopeChangeSearchesImmediatelyAndInitialScopeFollowsTab() = runTest {
        val vm = SearchViewModel(library)
        vm.initScope(LibraryTab.ARCHIVE)
        vm.initScope(LibraryTab.FAVORITES) // ignored: only the first call counts
        assertEquals(SearchScope.ARCHIVE, vm.scope.value)
        backgroundScope.launch { vm.results.collect {} }
        vm.onQueryChange("fire")
        advanceTimeBy(300)
        runCurrent()
        assertEquals("fire" to SearchScope.ARCHIVE, library.lastSearch)
        vm.onScopeChange(SearchScope.FAVORITES)
        runCurrent()
        assertEquals("fire" to SearchScope.FAVORITES, library.lastSearch)
    }
}
