package app.sroka.feature.settings.impl

import kotlin.math.abs
import kotlin.math.roundToInt

/** Delete is enabled only when the typed text equals the account email (trimmed, case-insensitive). */
fun isDeleteConfirmed(typed: String, email: String?): Boolean =
    !email.isNullOrBlank() && typed.trim().equals(email.trim(), ignoreCase = true)

/** Reader body size at scale 1.0, in sp. */
const val READER_BASE_SP = 18

/** Text-size steps offered in the settings dialog (reader scale range is 0.8..1.6). */
val TextScaleSteps: List<Float> = listOf(0.8f, 0.9f, 1.0f, 1.15f, 1.3f, 1.45f, 1.6f)

fun textScaleSp(scale: Float): Int = (READER_BASE_SP * scale).roundToInt()

fun isDefaultTextScale(scale: Float): Boolean = abs(scale - 1.0f) < 0.01f

/** The step closest to [scale]. */
fun nearestTextScaleStep(scale: Float): Float = TextScaleSteps.minBy { abs(it - scale) }

/**
 * True when saving [value] would switch to another server (which signs out and wipes local data).
 * Settings is only reachable signed in.
 */
fun isServerSwitch(value: String, initial: String): Boolean =
    value.isNotBlank() && value.trim().trimEnd('/') != initial.trimEnd('/')
