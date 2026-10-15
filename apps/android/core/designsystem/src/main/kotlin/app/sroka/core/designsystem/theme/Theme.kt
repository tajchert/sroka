package app.sroka.core.designsystem.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext

/**
 * Light color scheme for the app.
 *
 * Brand fallback (no dynamic color): white surfaces, black text, teal accent.
 */
private val LightColorScheme = lightColorScheme(
    primary = Brand40,
    onPrimary = Paper,
    primaryContainer = Brand90,
    onPrimaryContainer = Brand10,
    secondary = Teal40,
    onSecondary = Gray99,
    secondaryContainer = Teal90,
    onSecondaryContainer = Teal10,
    tertiary = Orange40,
    onTertiary = Gray99,
    tertiaryContainer = Orange90,
    onTertiaryContainer = Orange10,
    error = Red40,
    onError = Gray99,
    errorContainer = Red90,
    onErrorContainer = Red10,
    background = Paper,
    onBackground = Ink,
    surface = Paper,
    onSurface = Ink,
    surfaceVariant = GrayVariant90,
    onSurfaceVariant = GrayVariant30,
    outline = GrayVariant50,
    outlineVariant = GrayVariant80,
)

/**
 * Dark color scheme for the app.
 *
 * Uses lighter tones of the color palette for better contrast.
 */
private val DarkColorScheme = darkColorScheme(
    primary = Brand80,
    onPrimary = Brand20,
    primaryContainer = Brand30,
    onPrimaryContainer = Brand90,
    secondary = Teal80,
    onSecondary = Teal20,
    secondaryContainer = Teal30,
    onSecondaryContainer = Teal90,
    tertiary = Orange80,
    onTertiary = Orange20,
    tertiaryContainer = Orange30,
    onTertiaryContainer = Orange90,
    error = Red80,
    onError = Red20,
    errorContainer = Red30,
    onErrorContainer = Red90,
    background = Ink,
    onBackground = Gray90,
    surface = Ink,
    onSurface = Gray90,
    surfaceVariant = GrayVariant30,
    onSurfaceVariant = GrayVariant80,
    outline = GrayVariant60,
    outlineVariant = GrayVariant30,
)

/**
 * Main theme composable for the Sroka app.
 *
 * ## Why Wrap MaterialTheme?
 *
 * 1. **Centralized Configuration**: Theme settings are in one place
 * 2. **Dynamic Colors Support**: Handles Android 12+ wallpaper-based colors
 * 3. **Consistent Defaults**: All screens use the same theme automatically
 *
 * ## Dynamic Colors
 *
 * On Android 12 (API 31) and above, the theme can use colors extracted
 * from the user's wallpaper. This is enabled by default but can be
 * disabled by setting [dynamicColor] to false.
 *
 * ## Usage
 *
 * ```kotlin
 * setContent {
 *     SrokaTheme {
 *         // Your app content
 *         MyScreen()
 *     }
 * }
 * ```
 *
 * @param darkTheme Whether to use dark theme. Defaults to system setting.
 * @param dynamicColor Whether to use Android 12+ dynamic colors. Defaults to true.
 * @param content The composable content to be themed.
 */
@Composable
fun SrokaTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = true,
    content: @Composable () -> Unit,
) {
    val colorScheme = when {
        // Use dynamic colors on Android 12+ when enabled
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            if (darkTheme) {
                dynamicDarkColorScheme(context)
            } else {
                dynamicLightColorScheme(context)
            }
        }
        // Fall back to our custom color schemes
        darkTheme -> DarkColorScheme
        else -> LightColorScheme
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = SrokaTypography,
        shapes = SrokaShapes,
        content = content,
    )
}
