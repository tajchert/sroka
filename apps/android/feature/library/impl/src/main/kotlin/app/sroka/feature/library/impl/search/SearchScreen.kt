package app.sroka.feature.library.impl.search

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Archive
import androidx.compose.material.icons.automirrored.rounded.Article
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.paging.LoadState
import androidx.paging.compose.LazyPagingItems
import androidx.paging.compose.collectAsLazyPagingItems
import androidx.paging.compose.itemKey
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.MatchIn
import app.sroka.core.model.SearchResult
import app.sroka.core.model.SearchScope
import app.sroka.feature.library.impl.R

/** Full-screen search (R8). Back or close returns to the list; a result opens the reader. */
@Composable
fun SearchRoute(
    initialTab: LibraryTab,
    onOpenItem: (String) -> Unit,
    onBack: () -> Unit,
    viewModel: SearchViewModel = hiltViewModel(),
) {
    LaunchedEffect(initialTab) { viewModel.initScope(initialTab) }
    val query by viewModel.query.collectAsStateWithLifecycle()
    val scope by viewModel.scope.collectAsStateWithLifecycle()
    val results = viewModel.results.collectAsLazyPagingItems()
    val resultCount by viewModel.resultCount.collectAsStateWithLifecycle()
    SearchScreen(
        query = query,
        scope = scope,
        results = results,
        resultCount = resultCount,
        onQueryChange = viewModel::onQueryChange,
        onScopeChange = viewModel::onScopeChange,
        onOpenItem = onOpenItem,
        onBack = onBack,
    )
}

@Composable
internal fun SearchScreen(
    query: String,
    scope: SearchScope,
    results: LazyPagingItems<SearchResult>,
    resultCount: Int?,
    onQueryChange: (String) -> Unit,
    onScopeChange: (SearchScope) -> Unit,
    onOpenItem: (String) -> Unit,
    onBack: () -> Unit,
) {
    BackHandler(onBack = onBack)
    val focus = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current
    LaunchedEffect(Unit) { focus.requestFocus() }

    Scaffold(containerColor = MaterialTheme.colorScheme.surfaceContainer) { padding ->
        Column(Modifier.padding(padding).imePadding().fillMaxSize()) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = stringResource(R.string.feature_library_close_search))
                }
                TextField(
                    value = query,
                    onValueChange = onQueryChange,
                    placeholder = { Text(stringResource(R.string.feature_library_search_hint)) },
                    singleLine = true,
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = Color.Transparent,
                        unfocusedContainerColor = Color.Transparent,
                        focusedIndicatorColor = Color.Transparent,
                        unfocusedIndicatorColor = Color.Transparent,
                    ),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { keyboard?.hide(); focusManager.clearFocus() }),
                    modifier = Modifier.weight(1f).focusRequester(focus),
                )
                if (query.isNotEmpty()) {
                    IconButton(onClick = { onQueryChange("") }) {
                        Icon(
                            Icons.Rounded.Close,
                            contentDescription = stringResource(R.string.feature_library_clear_search),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            Row(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ScopeChip(SearchScope.ALL, scope, R.string.feature_library_search_chip_all, onScopeChange)
                ScopeChip(SearchScope.ARCHIVE, scope, R.string.feature_library_search_chip_archive, onScopeChange)
                ScopeChip(SearchScope.FAVORITES, scope, R.string.feature_library_search_chip_favorites, onScopeChange)
            }
            val searching = query.isNotBlank()
            val loaded = results.loadState.refresh is LoadState.NotLoading
            when {
                !searching -> Message(R.string.feature_library_search_idle, null)
                loaded && results.itemCount == 0 ->
                    Message(R.string.feature_library_empty_search_title, R.string.feature_library_empty_search_body)
                else -> {
                    Text(
                        if (loaded && resultCount != null) {
                            pluralStringResource(R.plurals.feature_library_search_results, resultCount, resultCount)
                        } else {
                            stringResource(R.string.feature_library_search_results_loading)
                        },
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                    )
                    LazyColumn(Modifier.fillMaxSize()) {
                        items(count = results.itemCount, key = results.itemKey { it.summary.id }) { index ->
                            results[index]?.let { ResultRow(it, onClick = { onOpenItem(it.summary.id) }) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ScopeChip(value: SearchScope, selected: SearchScope, label: Int, onSelect: (SearchScope) -> Unit) {
    FilterChip(
        selected = value == selected,
        onClick = { onSelect(value) },
        label = { Text(stringResource(label)) },
        leadingIcon = if (value == selected) {
            { Icon(Icons.Rounded.Check, contentDescription = null, modifier = Modifier.padding(0.dp)) }
        } else {
            null
        },
        colors = FilterChipDefaults.filterChipColors(
            selectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
            selectedLabelColor = MaterialTheme.colorScheme.onPrimaryContainer,
            selectedLeadingIconColor = MaterialTheme.colorScheme.onPrimaryContainer,
        ),
    )
}

@Composable
private fun Message(title: Int, body: Int?) {
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
    ) {
        Icon(Icons.Rounded.Search, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(stringResource(title), style = MaterialTheme.typography.titleMedium)
        if (body != null) {
            Text(stringResource(body), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun ResultRow(result: SearchResult, onClick: () -> Unit) {
    val summary = result.summary
    val archived = summary.status == ItemStatus.ARCHIVED
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Icon(
            if (archived) Icons.Rounded.Archive else Icons.AutoMirrored.Rounded.Article,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(summary.displayTitle, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(
                "${summary.domain} · ${stringResource(matchLabel(result.matchIn, archived))}",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            result.snippet?.let { snippet ->
                Text(
                    highlightSnippet(
                        snippet,
                        result.highlights,
                        MaterialTheme.colorScheme.tertiaryContainer,
                        MaterialTheme.colorScheme.onTertiaryContainer,
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

internal fun matchLabel(matchIn: MatchIn, archived: Boolean): Int = when {
    archived && matchIn == MatchIn.TEXT -> R.string.feature_library_search_where_archive_text
    archived && matchIn == MatchIn.TITLE -> R.string.feature_library_search_where_archive_title
    archived -> R.string.feature_library_search_where_archive_both
    matchIn == MatchIn.TEXT -> R.string.feature_library_search_where_text
    matchIn == MatchIn.TITLE -> R.string.feature_library_search_where_title
    else -> R.string.feature_library_search_where_both
}

/** Snippet with [ranges] shown on a tertiaryContainer background; out-of-bounds ranges are clamped or dropped. */
internal fun highlightSnippet(snippet: String, ranges: List<IntRange>, background: Color, foreground: Color): AnnotatedString =
    buildAnnotatedString {
        append(snippet)
        val style = SpanStyle(background = background, color = foreground)
        ranges.forEach { r ->
            val start = r.first.coerceAtLeast(0)
            val end = (r.last + 1).coerceAtMost(snippet.length)
            if (start < end) addStyle(style, start, end)
        }
    }
