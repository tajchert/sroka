package app.sroka.feature.reader.impl.navigation

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.navigation3.runtime.EntryProviderScope
import androidx.navigation3.runtime.NavKey
import app.sroka.feature.reader.api.ReaderKey
import app.sroka.feature.reader.impl.R

/**
 * Reader entry.
 *
 * @param onBack leave the reader (also after archive/delete)
 */
fun EntryProviderScope<NavKey>.readerEntries(
    onBack: () -> Unit,
) {
    entry<ReaderKey> {
        // Placeholder until the reader feature is implemented.
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(stringResource(R.string.feature_reader_title))
        }
    }
}
