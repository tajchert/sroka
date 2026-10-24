package app.sroka.feature.reader.impl.navigation

import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.navigation3.ListDetailSceneStrategy
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.navigation3.runtime.EntryProviderScope
import androidx.navigation3.runtime.NavKey
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import app.sroka.core.designsystem.component.DetailPaneCard
import app.sroka.feature.reader.api.ReaderKey
import app.sroka.feature.reader.impl.ReaderViewModel
import app.sroka.feature.reader.impl.ui.ReaderScreen
import java.io.File

/**
 * Reader entry.
 *
 * @param onBack leave the reader (also after delete)
 * @param onArchived the open item was archived: pop and show an undo snackbar (unarchive via
 *   LibraryRepository.setStatus). Defaults to [onBack] with no undo.
 * @param isExpanded / onToggleExpanded R14.3: the list pane is collapsed; the app bar button toggles it
 * @param detailPaneActive true while the reader sits next to the list (two-pane, R13): it is drawn in
 *   the rounded detail card without a back arrow. When false it is full screen (phone, folded).
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
fun EntryProviderScope<NavKey>.readerEntries(
    onBack: () -> Unit,
    onArchived: (itemId: String) -> Unit = { onBack() },
    detailPaneActive: Boolean = false,
    isExpanded: () -> Boolean = { false },
    onToggleExpanded: (() -> Unit)? = null,
) {
    entry<ReaderKey>(metadata = ListDetailSceneStrategy.detailPane()) { key ->
        val viewModel = hiltViewModel<ReaderViewModel, ReaderViewModel.Factory>(
            key = key.itemId,
            creationCallback = { factory -> factory.create(key.itemId) },
        )
        val screen = @Composable { paneWidthDp: Int -> 
            ReaderScreen(
                viewModel = viewModel,
                articlesDir = File(LocalContext.current.filesDir, "articles"),
                onBack = onBack,
                onArchived = onArchived,
                itemId = key.itemId,
                detailPane = detailPaneActive,
                paneWidthDp = paneWidthDp,
                isExpanded = isExpanded(),
                onToggleExpanded = onToggleExpanded,
            )
        }
        if (detailPaneActive) {
            DetailPaneCard { BoxWithConstraints(Modifier.fillMaxSize()) { screen(maxWidth.value.toInt()) } }
        } else {
            screen(Int.MAX_VALUE)
        }
    }
}
