package app.sroka.feature.settings.impl

import app.sroka.core.designsystem.icon.SrokaIcons
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.ScaffoldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp

/** Section label: primary, labelLarge. */
@Composable
internal fun GroupLabel(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.primary,
        modifier = modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 8.dp),
    )
}

/** M3 radio list item; put inside a `Modifier.selectableGroup()` parent. */
@Composable
internal fun RadioOptionRow(
    title: String,
    selected: Boolean,
    onClick: () -> Unit,
    minHeight: androidx.compose.ui.unit.Dp = 56.dp,
    sub: String? = null,
    enabled: Boolean = true,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = minHeight)
            .selectable(selected = selected, enabled = enabled, role = Role.RadioButton, onClick = onClick)
            .padding(start = 16.dp, end = 24.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        RadioButton(selected = selected, onClick = null, enabled = enabled)
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            if (sub != null) {
                Text(sub, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/**
 * Scaffold of a settings sub-page. Full screen it has a back arrow; as a detail pane ([detailPane],
 * inside `DetailPaneCard`, which already handles insets) it has none and is transparent (R14.4).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SettingsPageScaffold(
    title: String,
    detailPane: Boolean,
    onBack: () -> Unit,
    snackbarHost: @Composable () -> Unit = {},
    content: @Composable (PaddingValues) -> Unit,
) {
    Scaffold(
        containerColor = if (detailPane) Color.Transparent else MaterialTheme.colorScheme.background,
        contentWindowInsets = if (detailPane) WindowInsets(0) else ScaffoldDefaults.contentWindowInsets,
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = {
                    if (!detailPane) {
                        IconButton(onClick = onBack) {
                            Icon(SrokaIcons.ArrowBack, stringResource(R.string.feature_settings_back))
                        }
                    }
                },
                colors = if (detailPane) {
                    TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent)
                } else {
                    TopAppBarDefaults.topAppBarColors()
                },
                windowInsets = if (detailPane) WindowInsets(0) else TopAppBarDefaults.windowInsets,
            )
        },
        snackbarHost = snackbarHost,
        content = content,
    )
}
