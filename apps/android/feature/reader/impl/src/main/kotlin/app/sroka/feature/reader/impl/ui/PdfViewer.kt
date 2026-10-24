package app.sroka.feature.reader.impl.ui

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.sroka.feature.reader.impl.PdfDocument
import app.sroka.feature.reader.impl.R
import app.sroka.feature.reader.impl.RefCountedCache
import java.io.File
import kotlinx.coroutines.flow.distinctUntilChanged

private const val MAX_ZOOM = 4f
private const val DOUBLE_TAP_ZOOM = 2.5f
private const val DEFAULT_ASPECT = 1.414f
private const val CACHE_BYTES = 48L * 1024 * 1024

/** Open state of the document behind [PdfViewer]. */
private sealed interface PdfOpen {
    data object Loading : PdfOpen
    data object Failed : PdfOpen
    data class Ready(val doc: PdfDocument) : PdfOpen
}

/**
 * Native PDF viewer: a vertical lazy list of pages rendered with [android.graphics.pdf.PdfRenderer] at
 * the viewport width x density on a background thread, bitmaps held in a small leased LRU and recycled,
 * pinch-zoom (and double-tap) with pan. Opens at [initialPage]; [onPage] gets `(pageIndex, pageCount)`
 * whenever the current page changes. [onUnreadable] shows the host's fallback (open with another app).
 */
@Composable
internal fun PdfViewer(
    file: File,
    initialPage: Int,
    onPage: (page: Int, pageCount: Int) -> Unit,
    onUnreadable: @Composable () -> Unit,
    modifier: Modifier = Modifier,
) {
    val open by produceState<PdfOpen>(PdfOpen.Loading, file) {
        value = PdfDocument.open(file)?.let { PdfOpen.Ready(it) } ?: PdfOpen.Failed
    }
    when (val o = open) {
        PdfOpen.Loading -> Box(modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator() }
        PdfOpen.Failed -> Column(
            modifier.fillMaxSize().padding(32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                stringResource(R.string.feature_reader_pdf_unreadable_title),
                style = MaterialTheme.typography.titleMedium,
                textAlign = TextAlign.Center,
            )
            Text(stringResource(R.string.feature_reader_pdf_unreadable), textAlign = TextAlign.Center)
            onUnreadable()
        }
        is PdfOpen.Ready -> {
            DisposableEffect(o.doc) { onDispose { o.doc.close() } }
            PdfPages(o.doc, initialPage, onPage, modifier)
        }
    }
}

@Composable
private fun PdfPages(
    doc: PdfDocument,
    initialPage: Int,
    onPage: (page: Int, pageCount: Int) -> Unit,
    modifier: Modifier,
) {
    val density = LocalDensity.current
    val listState = rememberLazyListState(initialFirstVisibleItemIndex = initialPage.coerceIn(0, doc.pageCount - 1))
    val aspects = remember(doc) { mutableStateMapOf<Int, Float>() }
    var scale by remember { mutableFloatStateOf(1f) }
    var offsetX by remember { mutableFloatStateOf(0f) }

    // The page "being read": the first one whose bottom edge is past a third of the viewport.
    val currentPage by remember(doc) {
        derivedStateOf {
            val info = listState.layoutInfo
            val line = info.viewportSize.height / 3
            info.visibleItemsInfo.firstOrNull { it.offset + it.size > line }?.index ?: listState.firstVisibleItemIndex
        }
    }
    LaunchedEffect(doc) {
        snapshotFlow { currentPage }.distinctUntilChanged().collect { onPage(it, doc.pageCount) }
    }

    BoxWithConstraints(modifier.fillMaxSize().background(MaterialTheme.colorScheme.surfaceContainerHighest).clipToBounds()) {
        val widthPx = with(density) { maxWidth.roundToPx() }
        val viewportHeight: Dp = maxHeight
        val cache = remember(doc, widthPx) {
            RefCountedCache<Int, Bitmap>(CACHE_BYTES, { it.allocationByteCount.toLong() }, { it.recycle() })
        }
        DisposableEffect(cache) { onDispose { cache.clear() } }

        fun clampOffset(x: Float, s: Float): Float {
            val limit = (s - 1f) * widthPx / 2f
            return x.coerceIn(-limit, limit)
        }

        Box(
            Modifier
                .fillMaxSize()
                .pointerInput(Unit) {
                    detectTapGestures(onDoubleTap = {
                        if (scale > 1.01f) {
                            scale = 1f
                            offsetX = 0f
                        } else {
                            scale = DOUBLE_TAP_ZOOM
                        }
                    })
                }
                .pointerInput(Unit) {
                    awaitEachGesture {
                        awaitFirstDown(requireUnconsumed = false)
                        do {
                            val event = awaitPointerEvent(PointerEventPass.Main)
                            val pressed = event.changes.count { it.pressed }
                            if (pressed >= 2) {
                                val zoom = event.calculateZoom()
                                val pan = event.calculatePan()
                                scale = (scale * zoom).coerceIn(1f, MAX_ZOOM)
                                offsetX = clampOffset(offsetX + pan.x, scale)
                                event.changes.forEach { if (it.positionChanged()) it.consume() }
                            } else if (scale > 1f) {
                                // One finger while zoomed: horizontal pan here, vertical scrolling stays with the list.
                                offsetX = clampOffset(offsetX + event.calculatePan().x, scale)
                            }
                        } while (event.changes.any { it.pressed })
                    }
                }
                .graphicsLayer {
                    scaleX = scale
                    scaleY = scale
                    translationX = offsetX
                    transformOrigin = TransformOrigin(0.5f, 0f)
                },
        ) {
            LazyColumn(
                Modifier.fillMaxSize(),
                state = listState,
                // Zooming from the top edge pushes the bottom out of view: pad so the last page can still be reached.
                contentPadding = PaddingValues(bottom = viewportHeight * (1f - 1f / scale)),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(count = doc.pageCount, key = { it }) { index ->
                    PdfPage(doc, cache, index, widthPx, aspects)
                }
            }
        }

        PageBadge(
            text = stringResource(R.string.feature_reader_pdf_page_of, currentPage + 1, doc.pageCount),
            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 16.dp),
        )
    }
}

@Composable
private fun PdfPage(
    doc: PdfDocument,
    cache: RefCountedCache<Int, Bitmap>,
    index: Int,
    widthPx: Int,
    aspects: MutableMap<Int, Float>,
) {
    var lease by remember(cache, index) { mutableStateOf<RefCountedCache.Lease<Bitmap>?>(null) }
    LaunchedEffect(cache, index) {
        val cached = cache.acquire(index)
        if (cached != null) {
            lease = cached
            return@LaunchedEffect
        }
        val rendered = doc.render(index, widthPx) ?: return@LaunchedEffect
        aspects[index] = rendered.aspect
        // No suspension between put and the assignment, so cancellation cannot leak the lease.
        lease = cache.put(index, rendered.bitmap)
    }
    DisposableEffect(cache, index) {
        onDispose {
            lease?.let(cache::release)
            lease = null
        }
    }
    val aspect = aspects[index] ?: aspects.values.firstOrNull() ?: DEFAULT_ASPECT
    val description = stringResource(R.string.feature_reader_pdf_page, index + 1, doc.pageCount)
    Box(
        Modifier
            .fillMaxWidth()
            .aspectRatioOf(aspect)
            .background(Color.White)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        val bitmap = lease?.value
        if (bitmap != null && !bitmap.isRecycled) {
            Image(bitmap.asImageBitmap(), contentDescription = null, contentScale = ContentScale.FillWidth, modifier = Modifier.fillMaxWidth())
        }
    }
}

/** width : height = 1 : [aspect] (aspect is height / width). */
private fun Modifier.aspectRatioOf(aspect: Float): Modifier = this.aspectRatio(1f / aspect)

@Composable
private fun PageBadge(text: String, modifier: Modifier = Modifier) {
    Surface(
        modifier,
        shape = RoundedCornerShape(50),
        color = MaterialTheme.colorScheme.inverseSurface.copy(alpha = 0.85f),
        contentColor = MaterialTheme.colorScheme.inverseOnSurface,
    ) {
        Text(text, Modifier.padding(horizontal = 12.dp, vertical = 6.dp), style = MaterialTheme.typography.labelMedium)
    }
}

/** Placeholder shown by hosts while the PDF is fetched. */
@Composable
internal fun PdfLoadingPlaceholder(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator() }
}
