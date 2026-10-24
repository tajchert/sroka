package app.sroka.feature.library.impl

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.sroka.core.designsystem.preview.FoldablePreviews
import app.sroka.core.designsystem.theme.SrokaTheme
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.SearchScope
import app.sroka.feature.library.impl.detail.DetailPlaceholderContent
import app.sroka.feature.library.impl.tags.TagsContent
import app.sroka.feature.library.impl.list.DropState
import app.sroka.feature.library.impl.list.LibraryListContent
import app.sroka.feature.library.impl.list.LibraryListUiState
import app.sroka.feature.library.impl.list.ListScope
import app.sroka.feature.library.impl.list.UploadCard
import app.sroka.core.model.ItemSummary
import app.sroka.core.model.PdfUploadError
import app.sroka.feature.library.impl.search.SearchContent
import com.android.tools.screenshot.PreviewTest

@Composable
private fun ListFixture(
    darkTheme: Boolean,
    twoPane: Boolean,
    dropState: DropState = DropState.Idle,
    items: List<ItemSummary> = sampleItems,
    uploadCards: List<UploadCard> = emptyList(),
) {
    SrokaTheme(darkTheme = darkTheme) {
        LibraryListContent(
            scope = ListScope.Tab(LibraryTab.MY_LIST),
            state = LibraryListUiState(email = "magpie@example.com"),
            snackbarHostState = remember { SnackbarHostState() },
            refreshing = false,
            onRefresh = {},
            isEmpty = false,
            listState = rememberLazyListState(),
            itemCount = { items.size },
            itemAt = { items.getOrNull(it) },
            itemKey = { items[it].id },
            itemContentType = { "item" },
            onSortChange = {},
            onOpenSearch = {},
            onOpenSettings = {},
            onBack = null,
            onSignIn = {},
            onAddLink = {},
            onOpenItem = {},
            onLongClick = {},
            onArchive = {},
            selectedItemId = if (twoPane) "i2" else null,
            twoPane = twoPane,
            navRailShown = twoPane,
            dropState = dropState,
            uploadCards = uploadCards,
        )
    }
}

@PreviewTest
@FoldablePreviews
@Composable
fun LibraryListLight() = ListFixture(darkTheme = false, twoPane = false)

@PreviewTest
@FoldablePreviews
@Composable
fun LibraryListDark() = ListFixture(darkTheme = true, twoPane = false)

/** Drag-to-save (R15.1): drop target idle (drag started) and hovered; the list dims. */
@PreviewTest
@FoldablePreviews
@Composable
fun LibraryListDropTarget() = ListFixture(darkTheme = true, twoPane = false, dropState = DropState.Active)

@PreviewTest
@FoldablePreviews
@Composable
fun LibraryListDropTargetHovered() = ListFixture(darkTheme = true, twoPane = false, dropState = DropState.Hovered)

/** PDF rows: icon tile instead of the lead image, "PDF \u00b7 2.4 MB" subtitle. */
@PreviewTest
@FoldablePreviews
@Composable
fun LibraryListPdfRows() = ListFixture(darkTheme = false, twoPane = false, items = samplePdfItems)

/** "Uploading 2 PDFs" card above the list. */
@PreviewTest
@FoldablePreviews
@Composable
fun LibraryListUploading() = ListFixture(
    darkTheme = false, twoPane = false, items = samplePdfItems,
    uploadCards = listOf(UploadCard.Uploading(count = 2, fraction = 0.42f)),
)

/** An upload still sending next to a failed one (typed message, retry/dismiss). */
@PreviewTest
@FoldablePreviews
@Composable
fun LibraryListUploadFailed() = ListFixture(
    darkTheme = true, twoPane = false, items = samplePdfItems,
    uploadCards = listOf(
        UploadCard.Uploading(count = 1, fraction = null),
        UploadCard.Failed("scan-final.pdf", PdfUploadError.NETWORK, more = 1),
    ),
)

/** The 360dp list pane of the unfolded layout: rounded rows, the second one selected. */
@PreviewTest
@FoldablePreviews
@Composable
fun LibraryListTwoPane() {
    SrokaTheme(darkTheme = false) {
        androidx.compose.foundation.layout.Box(Modifier.width(360.dp).fillMaxHeight()) {
            ListFixture(darkTheme = false, twoPane = true)
        }
    }
}

@PreviewTest
@FoldablePreviews
@Composable
fun SearchResultsWithHighlights() {
    SrokaTheme(darkTheme = false) {
        SearchContent(
            query = "magpie",
            scope = SearchScope.ALL,
            loaded = true,
            itemCount = sampleSearchResults.size,
            itemAt = { sampleSearchResults.getOrNull(it) },
            itemKey = { sampleSearchResults[it].summary.id },
            resultCount = sampleSearchResults.size,
            onQueryChange = {},
            onScopeChange = {},
            onOpenItem = {},
            onBack = {},
            focus = null,
        )
    }
}

/** Search as the 360dp list pane (R14.1): rounded rows, the open result highlighted. */
@PreviewTest
@FoldablePreviews
@Composable
fun SearchTwoPane() {
    SrokaTheme(darkTheme = false) {
        androidx.compose.foundation.layout.Box(Modifier.width(360.dp).fillMaxHeight()) {
            SearchContent(
                query = "magpie",
                scope = SearchScope.ALL,
                loaded = true,
                itemCount = sampleSearchResults.size,
                itemAt = { sampleSearchResults.getOrNull(it) },
                itemKey = { sampleSearchResults[it].summary.id },
                resultCount = sampleSearchResults.size,
                onQueryChange = {},
                onScopeChange = {},
                onOpenItem = {},
                onBack = {},
                focus = null,
                selectedItemId = "i2",
                twoPane = true,
            )
        }
    }
}

/** Empty detail pane (R14.2) with the "Read next" button. */
@PreviewTest
@FoldablePreviews
@Composable
fun EmptyDetailPane() {
    SrokaTheme(darkTheme = false) {
        androidx.compose.foundation.layout.Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
            DetailPlaceholderContent(nextTitle = "How a magpie decides what to collect", onReadNext = {})
        }
    }
}

/** Tags list pane (R14.5) with the open tag highlighted. */
@PreviewTest
@FoldablePreviews
@Composable
fun TagsTwoPane() {
    SrokaTheme(darkTheme = true) {
        androidx.compose.foundation.layout.Box(Modifier.width(360.dp).fillMaxHeight()) {
            TagsContent(
                tags = sampleTags,
                avatar = "M",
                selectedTag = "nature",
                navRailShown = true,
                onOpenTag = {},
                onOpenSettings = {},
                onRename = {},
                onDelete = {},
            )
        }
    }
}
