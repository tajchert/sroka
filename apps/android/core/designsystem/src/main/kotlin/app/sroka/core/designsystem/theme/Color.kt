package app.sroka.core.designsystem.theme

import androidx.compose.ui.graphics.Color

/**
 * Color palette for the Sroka app design system.
 *
 * ## Color Naming Convention
 *
 * Colors are named with format: `{ColorFamily}{Shade}`
 * - ColorFamily: Brand, Teal, Orange, etc.
 * - Shade: 10 (lightest) to 90 (darkest) in steps of 10
 *
 * This follows Material 3 conventions and makes it easy to
 * create balanced light/dark color schemes.
 *
 * ## Usage
 *
 * These colors should NOT be used directly in composables.
 * Instead, use the semantic colors from MaterialTheme.colorScheme:
 *
 * ```kotlin
 * // DON'T do this:
 * Text(color = Brand40)
 *
 * // DO this:
 * Text(color = MaterialTheme.colorScheme.primary)
 * ```
 */

// Secondary - Teal palette
internal val Teal10 = Color(0xFF001F26)
internal val Teal20 = Color(0xFF003640)
internal val Teal30 = Color(0xFF004E5C)
internal val Teal40 = Color(0xFF006879)
internal val Teal80 = Color(0xFF4DD9F0)
internal val Teal90 = Color(0xFFACEDFF)

// Tertiary - Orange palette
internal val Orange10 = Color(0xFF2D1600)
internal val Orange20 = Color(0xFF4A2800)
internal val Orange30 = Color(0xFF693C00)
internal val Orange40 = Color(0xFF8A5100)
internal val Orange80 = Color(0xFFFFB86C)
internal val Orange90 = Color(0xFFFFDDB8)

// Error - Red palette
internal val Red10 = Color(0xFF410001)
internal val Red20 = Color(0xFF680003)
internal val Red30 = Color(0xFF930006)
internal val Red40 = Color(0xFFBA1B1B)
internal val Red80 = Color(0xFFFFB4A9)
internal val Red90 = Color(0xFFFFDAD4)

// Neutral - Gray palette for backgrounds and surfaces
internal val Gray10 = Color(0xFF1A1C1E)
internal val Gray20 = Color(0xFF2F3033)
internal val Gray90 = Color(0xFFE2E2E5)
internal val Gray95 = Color(0xFFF0F0F3)
internal val Gray99 = Color(0xFFFCFCFF)

// Neutral Variant - For containers and outlines
internal val GrayVariant30 = Color(0xFF42474E)
internal val GrayVariant50 = Color(0xFF72777F)
internal val GrayVariant60 = Color(0xFF8C9198)
internal val GrayVariant80 = Color(0xFFC2C7CF)
internal val GrayVariant90 = Color(0xFFDEE3EB)

// Brand fallback (DECISIONS A2): black/white neutrals + teal accent #1F8A84.
internal val Brand10 = Color(0xFF00201E)
internal val Brand20 = Color(0xFF003733)
internal val Brand30 = Color(0xFF00504B)
internal val Brand40 = Color(0xFF1F8A84)
internal val Brand80 = Color(0xFF7DD7CF)
internal val Brand90 = Color(0xFFB4EFE9)
internal val Ink = Color(0xFF111414)
internal val Paper = Color(0xFFFFFFFF)
