package app.sroka.feature.reader.impl

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.IOException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

/** A rendered page; [aspect] is height / width. */
internal class RenderedPage(val bitmap: Bitmap, val aspect: Float)

/**
 * Thin wrapper over [PdfRenderer]. The renderer allows one open page at a time and is not thread-safe,
 * so all calls are serialized on a single background thread and a mutex.
 */
internal class PdfDocument private constructor(
    private val descriptor: ParcelFileDescriptor,
    private val renderer: PdfRenderer,
) : AutoCloseable {
    val pageCount: Int = renderer.pageCount

    private val mutex = Mutex()
    private var closed = false

    /** Renders page [index] at [widthPx] wide (height follows the page's aspect) on a white background. */
    suspend fun render(index: Int, widthPx: Int): RenderedPage? = withContext(RENDER_DISPATCHER) {
        mutex.withLock {
            if (closed || index !in 0 until pageCount) return@withLock null
            renderer.openPage(index).use { page ->
                val width = widthPx.coerceAtLeast(1)
                val height = (width.toFloat() * page.height / page.width.coerceAtLeast(1)).roundToInt().coerceIn(1, MAX_HEIGHT_PX)
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                RenderedPage(bitmap, height.toFloat() / width)
            }
        }
    }

    /** Closes after any render in flight has finished (queued on the render thread). */
    override fun close() {
        CoroutineScope(RENDER_DISPATCHER).launch {
            mutex.withLock {
                if (!closed) {
                    closed = true
                    renderer.close()
                    descriptor.close()
                }
            }
        }
    }

    companion object {
        private const val MAX_HEIGHT_PX = 16_000

        @OptIn(ExperimentalCoroutinesApi::class)
        private val RENDER_DISPATCHER: CoroutineDispatcher = Dispatchers.IO.limitedParallelism(1)

        /** Opens [file]; null when it is not a readable PDF (corrupt, password protected, empty). */
        suspend fun open(file: File): PdfDocument? = withContext(RENDER_DISPATCHER) {
            var descriptor: ParcelFileDescriptor? = null
            try {
                descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
                val renderer = PdfRenderer(descriptor)
                if (renderer.pageCount == 0) {
                    renderer.close()
                    descriptor.close()
                    null
                } else {
                    PdfDocument(descriptor, renderer)
                }
            } catch (_: IOException) {
                descriptor?.close()
                null
            } catch (_: SecurityException) {
                descriptor?.close()
                null
            } catch (_: IllegalArgumentException) {
                descriptor?.close()
                null
            }
        }
    }
}
