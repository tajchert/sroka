package app.sroka.feature.library.impl.list

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import app.sroka.core.designsystem.icon.SrokaIcons
import app.sroka.core.model.LibraryTab
import app.sroka.core.model.tagKey
import app.sroka.feature.library.impl.R

/**
 * The home chip row under the search pill (proposal 08): destination chips My List / Archive (single
 * select; phones only, the rail hosts them on wide windows), a divider, then filter chips Favorites,
 * Under 10 min and the most-used tags (one tag at a time), and a trailing Tags chip that opens the
 * Tags screen. Filters toggle in place and combine with AND.
 *
 * @param onTabChange null hides the destination chips (the rail shows them)
 * @param onOpenTags null hides the trailing Tags chip
 */
@Composable
internal fun HomeChipRow(
    tab: LibraryTab,
    filters: ListFilters,
    topTags: List<String>,
    onTabChange: ((LibraryTab) -> Unit)?,
    onFiltersChange: (ListFilters) -> Unit,
    onOpenTags: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(ChipRowPadding),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (onTabChange != null) {
            DestinationChip(LibraryTab.MY_LIST, R.string.feature_library_my_list, tab, onTabChange)
            DestinationChip(LibraryTab.ARCHIVE, R.string.feature_library_archive, tab, onTabChange)
            VerticalDivider(Modifier.height(24.dp))
        }
        ToggleChip(
            label = stringResource(R.string.feature_library_favorites),
            icon = if (filters.favoritesOnly) SrokaIcons.StarFilled else SrokaIcons.Star,
            selected = filters.favoritesOnly,
            onClick = { onFiltersChange(filters.copy(favoritesOnly = !filters.favoritesOnly)) },
        )
        ToggleChip(
            label = stringResource(R.string.feature_library_chip_under_10),
            icon = if (filters.underTenMinutes) SrokaIcons.ScheduleFilled else SrokaIcons.Schedule,
            selected = filters.underTenMinutes,
            onClick = { onFiltersChange(filters.copy(underTenMinutes = !filters.underTenMinutes)) },
        )
        tagChips(topTags, filters.tag).forEach { name ->
            val selected = filters.tag != null && tagKey(filters.tag) == tagKey(name)
            ToggleChip(
                label = stringResource(R.string.feature_library_chip_tag, name),
                icon = null,
                selected = selected,
                onClick = { onFiltersChange(filters.copy(tag = if (selected) null else name)) },
            )
        }
        if (onOpenTags != null) {
            val label = stringResource(R.string.feature_library_tags)
            FilterChip(
                selected = false,
                onClick = onOpenTags,
                label = { Icon(SrokaIcons.Label, contentDescription = null, modifier = Modifier.size(18.dp)) },
                modifier = Modifier.semantics { contentDescription = label },
            )
        }
    }
}

/** The tag chips: the selected tag first (even when it dropped out of the top list), then the top tags. */
internal fun tagChips(topTags: List<String>, selected: String?): List<String> {
    if (selected == null) return topTags
    val key = tagKey(selected)
    return listOf(selected) + topTags.filter { tagKey(it) != key }
}

@Composable
private fun DestinationChip(value: LibraryTab, label: Int, current: LibraryTab, onSelect: (LibraryTab) -> Unit) {
    val scheme = MaterialTheme.colorScheme
    FilterChip(
        selected = value == current,
        onClick = { onSelect(value) },
        label = { Text(stringResource(label)) },
        colors = FilterChipDefaults.filterChipColors(
            selectedContainerColor = scheme.inverseSurface,
            selectedLabelColor = scheme.inverseOnSurface,
        ),
        border = FilterChipDefaults.filterChipBorder(enabled = true, selected = value == current, selectedBorderWidth = 0.dp),
    )
}

@Composable
private fun ToggleChip(label: String, icon: ImageVector?, selected: Boolean, onClick: () -> Unit) {
    FilterChip(
        selected = selected,
        onClick = onClick,
        label = { Text(label) },
        leadingIcon = icon?.let { { Icon(it, contentDescription = null, modifier = Modifier.size(18.dp)) } },
    )
}

private val ChipRowPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 4.dp)
