package app.sroka.core.data.upload

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File
import javax.inject.Inject
import kotlin.math.ceil
import kotlin.math.min

/** Encoded first-page preview of a PDF ([contentType] `image/webp` or `image/jpeg`). */
class PdfThumbnail(val bytes: ByteArray, val contentType: String)

/** Renders page 1 of a PDF for its list preview (api.md §5.9); null when it can't (corrupt, encrypted, OOM). */
fun interface PdfThumbnailRenderer {
    fun render(file: File): PdfThumbnail?
}

/**
 * [PdfRenderer] implementation: [WIDTH] px wide, height capped at 2× (taller pages are cropped at the
 * bottom), white background. WebP on API 30+, JPEG below (no lossy WebP encoder there).
 */
class AndroidPdfThumbnailRenderer @Inject constructor() : PdfThumbnailRenderer {

    override fun render(file: File): PdfThumbnail? = try {
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
            PdfRenderer(fd).use { renderer ->
                if (renderer.pageCount == 0) return null
                renderer.openPage(0).use { page -> encode(page) }
            }
        }
    } catch (e: Exception) {
        Log.w(TAG, "pdf thumbnail render failed: ${e.javaClass.simpleName}")
        null
    } catch (_: OutOfMemoryError) {
        Log.w(TAG, "pdf thumbnail render failed: out of memory")
        null
    }

    private fun encode(page: PdfRenderer.Page): PdfThumbnail {
        val scale = WIDTH.toFloat() / page.width
        val height = min(ceil(page.height * scale).toInt(), WIDTH * 2).coerceAtLeast(1)
        val bitmap = Bitmap.createBitmap(WIDTH, height, Bitmap.Config.ARGB_8888)
        try {
            bitmap.eraseColor(Color.WHITE) // pages may be transparent
            page.render(bitmap, null, Matrix().apply { setScale(scale, scale) }, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            val webp = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
            val format = if (webp) Bitmap.CompressFormat.WEBP_LOSSY else Bitmap.CompressFormat.JPEG
            val out = ByteArrayOutputStream()
            bitmap.compress(format, QUALITY, out)
            return PdfThumbnail(out.toByteArray(), if (webp) "image/webp" else "image/jpeg")
        } finally {
            bitmap.recycle()
        }
    }

    private companion object {
        const val TAG = "PdfThumbnail"
        const val WIDTH = 480
        const val QUALITY = 75
    }
}
