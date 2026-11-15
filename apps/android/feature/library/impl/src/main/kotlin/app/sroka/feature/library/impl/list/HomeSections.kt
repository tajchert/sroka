package app.sroka.feature.library.impl.list

import android.content.ClipDescription
import android.content.ClipboardManager
import android.os.Build
import android.view.textclassifier.TextClassifier
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.sroka.core.designsystem.icon.SrokaIcons
import app.sroka.core.model.ItemSummary
import app.sroka.core.model.extractFirstUrl
import app.sroka.feature.library.impl.R

/** Where "Save from Chrome" points until a store listing is live (one constant, brief "Store links"). */
internal const val GET_EXTENSION_URL = "https://sroka.app/#get"

/**
 * "Continue reading" (proposal 08): a section label and horizontally scrolling cards of articles in
 * progress. Drawn as the first item of the list, so it scrolls away with it.
 */
@Composable
internal fun ContinueReadingStrip(items: List<ItemSummary>, onOpenItem: (String) -> Unit, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().padding(bottom = 8.dp)) {
        Text(
            stringResource(R.string.feature_library_continue_reading),
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 8.dp).semantics { heading() },
        )
        LazyRow(
            contentPadding = PaddingValues(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(items, key = { it.id }) { item -> ContinueCard(item, onClick = { onOpenItem(item.id) }) }
        }
    }
}

@Composable
private fun ContinueCard(item: ItemSummary, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        modifier = Modifier.width(150.dp),
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                item.displayTitle,
                style = MaterialTheme.typography.titleSmall,
                maxLines = 2,
                minLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                item.readingMinutes?.let { stringResource(R.string.feature_library_continue_minutes_left, minutesLeft(it, item.progress)) }
                    ?: item.domain,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            LinearProgressIndicator(
                progress = { item.progress.coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth().height(3.dp),
                strokeCap = StrokeCap.Round,
                gapSize = 0.dp,
                drawStopIndicator = {},
            )
        }
    }
}

/**
 * First-run panel for an empty My List (proposal 01): mostly icons, a few words per way to save.
 * A done step shows a check instead of its icon tile.
 */
@Composable
internal fun OnboardingPanel(
    extensionDone: Boolean,
    clipboardHasLink: Boolean,
    onGetExtension: () -> Unit,
    onPaste: () -> Unit,
    onSaveClipboard: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier.widthIn(max = 420.dp).fillMaxWidth().padding(horizontal = 24.dp, vertical = 32.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            stringResource(R.string.feature_library_onboarding_title),
            style = MaterialTheme.typography.headlineSmall,
            modifier = Modifier.padding(bottom = 12.dp).semantics { heading() },
        )
        OnboardingStep(SrokaIcons.Share, stringResource(R.string.feature_library_onboarding_share), done = false, onClick = null)
        OnboardingStep(
            SrokaIcons.OpenInBrowser,
            stringResource(R.string.feature_library_onboarding_extension),
            done = extensionDone,
            onClick = onGetExtension.takeUnless { extensionDone },
        )
        OnboardingStep(SrokaIcons.AddLink, stringResource(R.string.feature_library_onboarding_paste), done = false, onClick = onPaste)
        if (clipboardHasLink) {
            AssistChip(
                onClick = onSaveClipboard,
                label = { Text(stringResource(R.string.feature_library_onboarding_clipboard)) },
                leadingIcon = { Icon(SrokaIcons.Add, contentDescription = null, modifier = Modifier.size(18.dp)) },
                modifier = Modifier.padding(start = 56.dp),
            )
        }
    }
}

@Composable
private fun OnboardingStep(icon: ImageVector, label: String, done: Boolean, onClick: (() -> Unit)?) {
    val scheme = MaterialTheme.colorScheme
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .clip(RoundedCornerShape(12.dp))
            .then(if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(40.dp).background(if (done) scheme.primary else scheme.surfaceContainerHigh, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (done) {
                Icon(SrokaIcons.Check, contentDescription = stringResource(R.string.feature_library_onboarding_done), tint = scheme.onPrimary)
            } else {
                Icon(icon, contentDescription = null, tint = scheme.onSurfaceVariant)
            }
        }
        Text(
            label,
            style = MaterialTheme.typography.bodyLarge,
            color = if (onClick != null) scheme.primary else scheme.onSurface,
            modifier = Modifier.weight(1f),
        )
    }
}

/**
 * True when the clipboard probably holds an http(s) link, decided from the [ClipDescription] only where
 * the system classified it (API 31+), so the clip is not read (no "pasted" toast) until the user taps.
 * Older systems have no classifier and no toast: the text itself is checked. Never logs the contents.
 */
internal fun clipboardMayHoldLink(clipboard: ClipboardManager): Boolean {
    val description = try {
        clipboard.primaryClipDescription
    } catch (_: SecurityException) {
        null
    } ?: return false
    if (!description.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN) &&
        !description.hasMimeType(ClipDescription.MIMETYPE_TEXT_HTML) &&
        !description.hasMimeType(ClipDescription.MIMETYPE_TEXT_URILIST)
    ) {
        return false
    }
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        description.classificationStatus == ClipDescription.CLASSIFICATION_COMPLETE &&
            description.getConfidenceScore(TextClassifier.TYPE_URL) >= URL_CONFIDENCE
    } else {
        readClipboardLink(clipboard) != null
    }
}

/** The first http(s) URL in the clipboard text, or null. Reads the clip: call on a user action (or below API 31). */
internal fun readClipboardLink(clipboard: ClipboardManager): String? {
    val text = try {
        clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()
    } catch (_: SecurityException) {
        null
    }
    return text?.let(::extractFirstUrl)
}

private const val URL_CONFIDENCE = 0.5f
