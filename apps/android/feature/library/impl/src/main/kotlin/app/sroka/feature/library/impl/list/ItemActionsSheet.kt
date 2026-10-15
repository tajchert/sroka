package app.sroka.feature.library.impl.list

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import app.sroka.core.ui.openExternalLink
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.automirrored.outlined.Label
import androidx.compose.material.icons.outlined.OpenInBrowser
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.StarBorder
import androidx.compose.material.icons.outlined.Unarchive
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.sroka.core.model.Item
import app.sroka.core.model.ItemStatus
import app.sroka.feature.library.impl.R

/** Long-press actions for one item. Destructive and tag actions are delegated to the caller's dialogs. */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
internal fun ItemActionsSheet(
    item: Item,
    onDismiss: () -> Unit,
    onToggleFavorite: () -> Unit,
    onToggleArchive: () -> Unit,
    onEditTags: () -> Unit,
    onRefresh: () -> Unit,
    onDelete: () -> Unit,
) {
    val context = LocalContext.current
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.navigationBarsPadding()) {
            Text(
                item.displayTitle,
                style = MaterialTheme.typography.titleMedium,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
            )
            ActionRow(
                if (item.isFavorite) Icons.Filled.Star else Icons.Outlined.StarBorder,
                stringResource(if (item.isFavorite) R.string.feature_library_action_unfavorite else R.string.feature_library_action_favorite),
            ) { onToggleFavorite(); onDismiss() }
            val archived = item.status == ItemStatus.ARCHIVED
            ActionRow(
                if (archived) Icons.Outlined.Unarchive else Icons.Outlined.Archive,
                stringResource(if (archived) R.string.feature_library_action_unarchive else R.string.feature_library_action_archive),
            ) { onToggleArchive(); onDismiss() }
            ActionRow(Icons.AutoMirrored.Outlined.Label, stringResource(R.string.feature_library_action_edit_tags)) { onEditTags() }
            ActionRow(Icons.Outlined.Share, stringResource(R.string.feature_library_action_share)) {
                shareLink(context, item.url)
                onDismiss()
            }
            ActionRow(Icons.Outlined.OpenInBrowser, stringResource(R.string.feature_library_action_open_original)) {
                openOriginal(context, item.url)
                onDismiss()
            }
            ActionRow(Icons.Outlined.Refresh, stringResource(R.string.feature_library_action_refresh)) { onRefresh(); onDismiss() }
            ActionRow(Icons.Outlined.Delete, stringResource(R.string.feature_library_action_delete), destructive = true) { onDelete() }
        }
    }
}

@Composable
private fun ActionRow(icon: ImageVector, label: String, destructive: Boolean = false, onClick: () -> Unit) {
    val tint = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant
    ListItem(
        headlineContent = {
            Text(label, color = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface)
        },
        leadingContent = { Icon(icon, contentDescription = null, tint = tint) },
        modifier = Modifier.clickable(onClick = onClick),
    )
}

private fun shareLink(context: Context, url: String) {
    val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, url)
    startSafely(context, Intent.createChooser(send, null))
}

private fun openOriginal(context: Context, url: String) {
    openExternalLink(context, url)
}

private fun startSafely(context: Context, intent: Intent) {
    try {
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (_: ActivityNotFoundException) {
        // No handler installed; nothing useful to show.
    }
}
