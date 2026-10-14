package app.sroka.feature.reader.impl.navigation

import androidx.compose.ui.platform.LocalContext
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.navigation3.runtime.EntryProviderScope
import androidx.navigation3.runtime.NavKey
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
 */
fun EntryProviderScope<NavKey>.readerEntries(
    onBack: () -> Unit,
    onArchived: (itemId: String) -> Unit = { onBack() },
) {
    entry<ReaderKey> { key ->
        val viewModel = hiltViewModel<ReaderViewModel, ReaderViewModel.Factory>(
            key = key.itemId,
            creationCallback = { factory -> factory.create(key.itemId) },
        )
        ReaderScreen(
            viewModel = viewModel,
            articlesDir = File(LocalContext.current.filesDir, "articles"),
            onBack = onBack,
            onArchived = onArchived,
            itemId = key.itemId,
        )
    }
}
