package app.sroka.feature.reader.impl.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.tooling.preview.Preview
import app.sroka.core.designsystem.theme.SrokaTheme
import app.sroka.core.model.ItemKind
import app.sroka.core.model.ItemStatus
import app.sroka.core.model.ItemSummary
import app.sroka.core.model.OfflineState
import app.sroka.core.model.ParseStatus
import app.sroka.core.model.ReaderFont
import app.sroka.core.model.ReaderLineSpacing
import app.sroka.core.model.ReaderTheme
import app.sroka.core.model.UserPreferences
import app.sroka.feature.reader.impl.EffectiveTheme
import com.android.tools.screenshot.PreviewTest

private val NextItem = ItemSummary(
    id = "next",
    displayTitle = "Why every app needs an offline mode",
    domain = "example.com",
    excerpt = null,
    readingMinutes = 6,
    status = ItemStatus.UNREAD,
    isFavorite = false,
    progress = 0f,
    parseStatus = ParseStatus.OK,
    offline = OfflineState.DOWNLOADED,
    thumbnailPath = null,
    tags = emptyList(),
    savedAt = 1_760_400_000_000L,
    kind = ItemKind.ARTICLE,
)

@Composable
private fun SheetPreview(dark: Boolean, prefs: UserPreferences) {
    SrokaTheme(darkTheme = dark) {
        Surface(color = MaterialTheme.colorScheme.surfaceContainerLow) {
            AppearanceSheetContent(prefs, onTheme = {}, onFont = {}, onSpacing = {}, onTextScale = {})
        }
    }
}

@Composable
private fun EndCardPreview(theme: EffectiveTheme, dark: Boolean, archived: Boolean, next: ItemSummary?, minutes: Int?) {
    SrokaTheme(darkTheme = dark) {
        Box(Modifier.background(Color(theme.backgroundArgb))) {
            EndOfArticleCard(
                minutes = minutes,
                archived = archived,
                next = next,
                theme = theme,
                onArchive = {},
                onKeep = {},
                onOpenNext = {},
            )
        }
    }
}

@PreviewTest
@Preview(name = "AppearanceSepiaSerif", showBackground = true, widthDp = 411, apiLevel = 36)
@Composable
fun AppearanceSheetSepiaSerif() =
    SheetPreview(false, UserPreferences(readerTheme = ReaderTheme.SEPIA, readerFont = ReaderFont.SERIF, readerTextScale = 1.2f))

@PreviewTest
@Preview(name = "AppearanceDarkDefaults", showBackground = true, widthDp = 411, apiLevel = 36)
@Composable
fun AppearanceSheetDark() =
    SheetPreview(true, UserPreferences(readerTheme = ReaderTheme.DARK, readerLineSpacing = ReaderLineSpacing.LOOSE))

@PreviewTest
@Preview(name = "EndCardNext", showBackground = true, widthDp = 411, apiLevel = 36)
@Composable
fun EndCardWithNext() = EndCardPreview(EffectiveTheme.LIGHT, dark = false, archived = false, next = NextItem, minutes = 7)

@PreviewTest
@Preview(name = "EndCardNoNextSepia", showBackground = true, widthDp = 411, apiLevel = 36)
@Composable
fun EndCardWithoutNext() = EndCardPreview(EffectiveTheme.SEPIA, dark = false, archived = false, next = null, minutes = null)

@PreviewTest
@Preview(name = "EndCardArchivedDark", showBackground = true, widthDp = 411, apiLevel = 36)
@Composable
fun EndCardArchivedDark() = EndCardPreview(EffectiveTheme.DARK, dark = true, archived = true, next = NextItem, minutes = 7)
