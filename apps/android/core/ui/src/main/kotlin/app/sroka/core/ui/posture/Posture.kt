package app.sroka.core.ui.posture

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker
import androidx.window.layout.WindowMetricsCalculator
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/** How the reader is arranged for the current device posture (R15.2). */
sealed interface ReaderLayout {
    data object Normal : ReaderLayout

    /** Half-opened with a horizontal hinge; the hinge spans [hingeTopPx]..[hingeBottomPx] in WINDOW coordinates. */
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

/** The hinge in a container's own coordinates: article ends at [topPx], controls start at [bottomPx]. */
data class LocalSplit(val topPx: Int, val bottomPx: Int)

/**
 * Converts the hinge (window coordinates) into the coordinates of a container whose top edge sits at
 * [containerTopPx] in the window and is [containerHeightPx] tall. Null when the hinge does not fall inside the
 * container (nothing sensible to split); the bottom is clamped to the container.
 */
fun localSplit(hingeTopPx: Int, hingeBottomPx: Int, containerTopPx: Int, containerHeightPx: Int): LocalSplit? {
    val top = hingeTopPx - containerTopPx
    val bottom = hingeBottomPx - containerTopPx
    if (containerHeightPx <= 0 || bottom < top || top <= 0 || top >= containerHeightPx) return null
    return LocalSplit(top, bottom.coerceAtMost(containerHeightPx))
}

/** App-shell decisions that follow from the posture. */
data class ShellLayout(val hideNavigation: Boolean, val forceSinglePane: Boolean)

/** Tabletop with a reader on top: the reader owns the whole window (no navigation suite, no list pane, no card). */
fun shellLayoutFor(layout: ReaderLayout, readerOnTop: Boolean): ShellLayout {
    val full = layout is ReaderLayout.Tabletop && readerOnTop
    return ShellLayout(hideNavigation = full, forceSinglePane = full)
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

/** Current posture-based layout, from the window's folding feature (R15.2). */
@Composable
fun rememberReaderLayout(): ReaderLayout {
    val context = LocalContext.current
    val activity = remember(context) { context.findActivity() } ?: return ReaderLayout.Normal
    val flow = remember(activity) {
        WindowInfoTracker.getOrCreate(activity).windowLayoutInfo(activity).map { info ->
            val fold = info.displayFeatures.filterIsInstance<FoldingFeature>().firstOrNull()
            if (fold == null) {
                ReaderLayout.Normal
            } else {
                readerLayoutFor(
                    halfOpened = fold.state == FoldingFeature.State.HALF_OPENED,
                    horizontal = fold.orientation == FoldingFeature.Orientation.HORIZONTAL,
                    hingeTopPx = fold.bounds.top,
                    hingeBottomPx = fold.bounds.bottom,
                    windowHeightPx = WindowMetricsCalculator.getOrCreate().computeCurrentWindowMetrics(activity).bounds.height(),
                )
            }
        }.distinctUntilChanged()
    }
    return flow.collectAsState(ReaderLayout.Normal).value
}
