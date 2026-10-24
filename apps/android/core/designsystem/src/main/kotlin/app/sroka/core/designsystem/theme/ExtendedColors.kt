package app.sroka.core.designsystem.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

/** Brand colours that have no Material 3 role (redesign R2). Read via [srokaColors]. */
data class SrokaExtendedColors(
    /** Extended FAB, resync card, "Saved" check circle. */
    val brand: Color,
    val onBrand: Color,
    /** Offline card, partial save, "waiting" status lines (text/icon). */
    val warning: Color,
    val warningContainer: Color,
    /** Reading progress line and read-progress bar. */
    val progress: Color,
    val progressTrack: Color,
    /** Reader body text. */
    val readerBody: Color,
)

internal val DarkExtendedColors = SrokaExtendedColors(
    brand = BrandBlue,
    onBrand = Paper,
    warning = Color(0xFFE8CF86),
    warningContainer = Color(0xFF2A2619),
    progress = BrandYellow,
    progressTrack = DarkSurfaceHigh,
    readerBody = Color(0xFFD9D7D1),
)

internal val LightExtendedColors = SrokaExtendedColors(
    brand = BrandBlue,
    onBrand = Paper,
    warning = Color(0xFF7A5A00),
    warningContainer = Color(0xFFF6ECC9),
    progress = BrandYellow,
    progressTrack = LightSurfaceHighest,
    readerBody = Color(0xFF2B2E34),
)

val LocalSrokaColors = staticCompositionLocalOf { DarkExtendedColors }

val MaterialTheme.srokaColors: SrokaExtendedColors
    @Composable
    @ReadOnlyComposable
    get() = LocalSrokaColors.current
