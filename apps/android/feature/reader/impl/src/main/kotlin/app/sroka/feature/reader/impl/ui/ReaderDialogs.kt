package app.sroka.feature.reader.impl.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import app.sroka.core.model.ReaderFont
import app.sroka.core.model.ReaderLineSpacing
import app.sroka.core.model.ReaderTheme
import app.sroka.core.model.UserPreferences
import app.sroka.feature.reader.impl.EffectiveTheme
import app.sroka.feature.reader.impl.R
import app.sroka.feature.reader.impl.resolveTheme

@Composable
internal fun DeleteConfirmDialog(onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.feature_reader_delete_title)) },
        text = { Text(stringResource(R.string.feature_reader_delete_message)) },
        confirmButton = { TextButton(onClick = onConfirm) { Text(stringResource(R.string.feature_reader_delete)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.feature_reader_cancel)) } },
    )
}

/** The reader's "Aa" sheet: theme swatches, font, size and line spacing; every change applies live and persists. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AppearanceSheet(
    preferences: UserPreferences,
    onTheme: (ReaderTheme) -> Unit,
    onFont: (ReaderFont) -> Unit,
    onSpacing: (ReaderLineSpacing) -> Unit,
    onTextScale: (Float) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        AppearanceSheetContent(preferences, onTheme, onFont, onSpacing, onTextScale)
    }
}

@Composable
internal fun AppearanceSheetContent(
    preferences: UserPreferences,
    onTheme: (ReaderTheme) -> Unit,
    onFont: (ReaderFont) -> Unit,
    onSpacing: (ReaderLineSpacing) -> Unit,
    onTextScale: (Float) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .padding(horizontal = 24.dp)
            .padding(bottom = 24.dp)
            .navigationBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        SheetSection(R.string.feature_reader_theme) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                SWATCH_ORDER.forEach { theme ->
                    ThemeSwatch(theme, selected = preferences.readerTheme == theme, onClick = { onTheme(theme) }, modifier = Modifier.weight(1f))
                }
            }
        }
        SheetSection(R.string.feature_reader_font) {
            val fonts = ReaderFont.entries
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                fonts.forEachIndexed { index, font ->
                    SegmentedButton(
                        selected = preferences.readerFont == font,
                        onClick = { onFont(font) },
                        shape = SegmentedButtonDefaults.itemShape(index, fonts.size),
                    ) {
                        Text(
                            stringResource(if (font == ReaderFont.SERIF) R.string.feature_reader_font_serif else R.string.feature_reader_font_sans),
                            fontFamily = if (font == ReaderFont.SERIF) FontFamily.Serif else FontFamily.SansSerif,
                        )
                    }
                }
            }
        }
        SheetSection(R.string.feature_reader_text_size) {
            val sizeLabel = stringResource(R.string.feature_reader_text_size)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("A", style = MaterialTheme.typography.bodySmall)
                Slider(
                    value = preferences.readerTextScale,
                    onValueChange = onTextScale,
                    valueRange = UserPreferences.READER_TEXT_SCALE_MIN..UserPreferences.READER_TEXT_SCALE_MAX,
                    steps = 7,
                    modifier = Modifier.weight(1f).semantics { contentDescription = sizeLabel },
                )
                Text("A", style = MaterialTheme.typography.titleLarge)
            }
        }
        SheetSection(R.string.feature_reader_spacing) {
            val spacings = ReaderLineSpacing.entries
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                spacings.forEachIndexed { index, spacing ->
                    SegmentedButton(
                        selected = preferences.readerLineSpacing == spacing,
                        onClick = { onSpacing(spacing) },
                        shape = SegmentedButtonDefaults.itemShape(index, spacings.size),
                    ) { Text(stringResource(spacing.label())) }
                }
            }
        }
    }
}

@Composable
private fun SheetSection(titleRes: Int, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            stringResource(titleRes),
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        content()
    }
}

/** A tile in the theme's own colours with an "Aa" sample; the selected one is ringed. */
@Composable
private fun ThemeSwatch(theme: ReaderTheme, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val ring = if (selected) {
        BorderStroke(2.dp, MaterialTheme.colorScheme.primary)
    } else {
        BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
    }
    val shape = RoundedCornerShape(14.dp)
    Column(
        modifier
            .clip(shape)
            .selectable(selected = selected, onClick = onClick, role = Role.RadioButton),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(56.dp)
                .clip(shape)
                .border(ring, shape),
        ) {
            if (theme == ReaderTheme.AUTO) {
                // Half light, half dark: it follows the app.
                Row(Modifier.matchParentSize()) {
                    SwatchHalf(resolveTheme(ReaderTheme.LIGHT, false), "A", Modifier.weight(1f).fillMaxHeight())
                    SwatchHalf(resolveTheme(ReaderTheme.DARK, true), "a", Modifier.weight(1f).fillMaxHeight())
                }
            } else {
                SwatchHalf(resolveTheme(theme, false), stringResource(R.string.feature_reader_swatch_sample), Modifier.matchParentSize())
            }
        }
        Text(
            stringResource(theme.label()),
            style = MaterialTheme.typography.labelMedium,
            color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun SwatchHalf(theme: EffectiveTheme, sample: String, modifier: Modifier) {
    Box(modifier.background(Color(theme.backgroundArgb)), contentAlignment = Alignment.Center) {
        Text(
            sample,
            style = MaterialTheme.typography.titleLarge,
            color = Color(theme.foregroundArgb),
        )
    }
}

private val SWATCH_ORDER = listOf(ReaderTheme.LIGHT, ReaderTheme.SEPIA, ReaderTheme.DARK, ReaderTheme.AUTO)

private fun ReaderLineSpacing.label(): Int = when (this) {
    ReaderLineSpacing.TIGHT -> R.string.feature_reader_spacing_tight
    ReaderLineSpacing.NORMAL -> R.string.feature_reader_spacing_normal
    ReaderLineSpacing.LOOSE -> R.string.feature_reader_spacing_loose
}

private fun ReaderTheme.label(): Int = when (this) {
    ReaderTheme.AUTO -> R.string.feature_reader_theme_auto
    ReaderTheme.LIGHT -> R.string.feature_reader_theme_light
    ReaderTheme.SEPIA -> R.string.feature_reader_theme_sepia
    ReaderTheme.DARK -> R.string.feature_reader_theme_dark
}
