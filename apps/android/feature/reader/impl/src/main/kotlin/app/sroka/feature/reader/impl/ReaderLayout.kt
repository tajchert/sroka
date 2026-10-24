package app.sroka.feature.reader.impl

import app.sroka.core.model.UserPreferences
import kotlin.math.roundToInt

/** How the reader is arranged for the current device posture (R15.2). */
sealed interface ReaderLayout {
    data object Normal : ReaderLayout

    /** Half-opened with a horizontal hinge: article above [hingeTopPx], controls below [hingeBottomPx] (window px). */
    data class Tabletop(val hingeTopPx: Int, val hingeBottomPx: Int) : ReaderLayout
}

/**
 * Pure posture decision from the folding feature's facts. Tabletop only for a half-opened,
 * horizontal hinge with a usable position; anything else (flat, folded, vertical hinge, none) is [ReaderLayout.Normal].
 */
fun readerLayoutFor(
    halfOpened: Boolean,
    horizontal: Boolean,
    hingeTopPx: Int,
    hingeBottomPx: Int,
    windowHeightPx: Int = Int.MAX_VALUE,
): ReaderLayout {
    if (!halfOpened || !horizontal) return ReaderLayout.Normal
    if (hingeTopPx <= 0 || hingeBottomPx < hingeTopPx || hingeBottomPx >= windowHeightPx) return ReaderLayout.Normal
    return ReaderLayout.Tabletop(hingeTopPx, hingeBottomPx)
}

/** Scrubber value to a reading fraction. */
fun scrubFraction(value: Float): Float = if (value.isFinite()) value.coerceIn(0f, 1f) else 0f

/** Whole percent shown as "42% read". */
fun percentRead(progress: Float): Int = (scrubFraction(progress) * 100f).roundToInt()

/** Minutes left of an article of [readingMinutes] total, at [progress]; null when the length is unknown. */
fun minutesLeft(readingMinutes: Int?, progress: Float): Int? {
    val total = readingMinutes?.takeIf { it > 0 } ?: return null
    return (total * (1f - scrubFraction(progress))).roundToInt().coerceAtLeast(0)
}

private const val BASE_PX = 18f
private const val SCALE_STEPS = 8

/** CSS body size in px for a reader text [scale] (the reader's base is 18 px). */
fun textSizePx(scale: Float): Int = (BASE_PX * scale).roundToInt()

/** One stepper press: [direction] -1 / +1 moves a slider step, clamped to the allowed range. */
fun steppedTextScale(scale: Float, direction: Int): Float {
    val min = UserPreferences.READER_TEXT_SCALE_MIN
    val max = UserPreferences.READER_TEXT_SCALE_MAX
    val step = (max - min) / SCALE_STEPS
    val index = ((scale - min) / step).roundToInt() + direction.coerceIn(-1, 1)
    return (min + index.coerceIn(0, SCALE_STEPS) * step).coerceIn(min, max)
}
