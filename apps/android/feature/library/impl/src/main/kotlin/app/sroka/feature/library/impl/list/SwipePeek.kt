package app.sroka.feature.library.impl.list

import android.content.Context
import android.provider.Settings
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import app.sroka.core.model.SwipeAction
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/** How far the first row slides to reveal the action behind it; enough for the full icon. */
private val PEEK_DISTANCE = 64.dp
private const val PEEK_OUT_MS = 280
private const val PEEK_HOLD_MS = 140L
private const val PEEK_BACK_MS = 280

/**
 * The side the one-time peek slides towards: the first side with an action, left first. Null when
 * both swipes are off (nothing to hint at) or the peek already played.
 */
internal fun SwipeConfig.peekSide(): SwipeSide? = when {
    hintShown -> null
    left != SwipeAction.NONE -> SwipeSide.LEFT
    right != SwipeAction.NONE -> SwipeSide.RIGHT
    else -> null
}

/** Material's swipe directions follow the layout direction; the setting names physical sides. */
internal fun SwipeSide.toDirection(rtl: Boolean): SwipeToDismissBoxValue =
    if ((this == SwipeSide.LEFT) != rtl) SwipeToDismissBoxValue.EndToStart else SwipeToDismissBoxValue.StartToEnd

/** Inverse of [toDirection]; [SwipeToDismissBoxValue.Settled] has no side. */
internal fun SwipeToDismissBoxValue.toSide(rtl: Boolean): SwipeSide? = when (this) {
    SwipeToDismissBoxValue.Settled -> null
    else -> if ((this == SwipeToDismissBoxValue.EndToStart) != rtl) SwipeSide.LEFT else SwipeSide.RIGHT
}

/** False when the system "remove animations" setting (animator duration scale 0) is on. */
internal fun animationsEnabled(context: Context): Boolean =
    Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) > 0f

/**
 * Horizontal offset in px for the first-run swipe hint, 0 except while it plays (about 700 ms: slide
 * out, hold, slide back). Purely visual: it never touches the swipe state, so no action can fire.
 * [onDone] runs once the peek finished, or at once when animations are off (the hint is then
 * skipped but counted as shown). A null [side] does nothing.
 */
@Composable
internal fun rememberPeekOffset(side: SwipeSide?, onDone: () -> Unit): Animatable<Float, *> {
    val offset = remember { Animatable(0f) }
    val context = LocalContext.current
    val density = LocalDensity.current
    val currentDone by rememberUpdatedState(onDone)
    LaunchedEffect(side) {
        if (side == null) return@LaunchedEffect
        if (!animationsEnabled(context)) {
            currentDone()
            return@LaunchedEffect
        }
        val distance = with(density) { PEEK_DISTANCE.toPx() } * if (side == SwipeSide.LEFT) -1f else 1f
        try {
            offset.animateTo(distance, tween(PEEK_OUT_MS, easing = FastOutSlowInEasing))
            delay(PEEK_HOLD_MS)
            offset.animateTo(0f, tween(PEEK_BACK_MS, easing = FastOutSlowInEasing))
            currentDone()
        } finally {
            withContext(NonCancellable) { offset.snapTo(0f) }
        }
    }
    return offset
}
