package app.sroka.feature.library.impl.detail

import app.sroka.core.designsystem.icon.SrokaIcons
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import app.sroka.core.designsystem.component.DetailPaneCard
import app.sroka.core.domain.LibraryRepository
import app.sroka.core.model.ItemSummary
import app.sroka.feature.library.impl.R
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn

/** The newest unread My List item (local Room only), offered by the empty detail pane's button. */
@HiltViewModel
class EmptyDetailViewModel @Inject constructor(repository: LibraryRepository) : ViewModel() {
    val nextUnread: StateFlow<ItemSummary?> = repository.observeNextUnread()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)
}

/** Empty detail pane on wide windows until an article is opened (R14.2). */
@Composable
fun DetailPlaceholder(onOpenItem: (String) -> Unit, viewModel: EmptyDetailViewModel = hiltViewModel()) {
    val next by viewModel.nextUnread.collectAsStateWithLifecycle()
    DetailPlaceholderContent(
        nextTitle = next?.displayTitle,
        onReadNext = { next?.let { onOpenItem(it.id) } },
    )
}

/** Stateless empty detail pane; [nextTitle] null hides the "Read next" button. */
@Composable
fun DetailPlaceholderContent(nextTitle: String?, onReadNext: () -> Unit) {
    DetailPaneCard {
        Column(
            Modifier.fillMaxSize().padding(32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
        ) {
            Icon(
                SrokaIcons.Bookmarks,
                contentDescription = null,
                modifier = Modifier.size(48.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(stringResource(R.string.feature_library_empty_detail_title), style = MaterialTheme.typography.titleMedium)
            Text(
                stringResource(R.string.feature_library_empty_detail_body),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (nextTitle != null) {
                FilledTonalButton(onClick = onReadNext, modifier = Modifier.padding(top = 16.dp)) {
                    Text(
                        stringResource(R.string.feature_library_read_next, nextTitle),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}
