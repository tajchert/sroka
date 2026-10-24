package app.sroka.feature.library.impl.list

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import app.sroka.core.designsystem.icon.SrokaIcons
import app.sroka.core.model.SortOrder
import app.sroka.feature.library.impl.R

/**
 * M3-style search pill (surfaceContainerHigh), shared by My List/Archive/Favourites and Tags. Its top
 * edge sits at status-bar inset + 8dp (the detail card aligns with it, R16.2). [onSortChange] null
 * omits the sort icon; [onOpenSettings] null omits the avatar (the rail hosts it).
 */
@Composable
internal fun SearchPill(
    hint: String,
    email: String,
    sort: SortOrder?,
    onSortChange: ((SortOrder) -> Unit)?,
    onOpenSearch: () -> Unit,
    onOpenSettings: (() -> Unit)?,
) {
    Surface(
        modifier = Modifier
            .windowInsetsPadding(WindowInsets.statusBars)
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .fillMaxWidth()
            .height(56.dp),
        shape = RoundedCornerShape(28.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        onClick = onOpenSearch,
    ) {
        Row(
            Modifier.padding(start = 16.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(SrokaIcons.Search, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(
                hint,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f).padding(start = 16.dp),
            )
            if (sort != null && onSortChange != null) SortMenu(sort, onSortChange)
            if (onOpenSettings != null) Avatar(email, onOpenSettings)
        }
    }
}

@Composable
private fun Avatar(email: String, onClick: () -> Unit) {
    val label = stringResource(R.string.feature_library_settings)
    Box(
        Modifier
            .size(48.dp)
            .clickable(onClick = onClick, role = Role.Button, onClickLabel = label),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(32.dp).background(MaterialTheme.colorScheme.primaryContainer, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                avatarLetter(email),
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onPrimaryContainer,
            )
        }
    }
}
