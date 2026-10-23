package app.pace.ipsc_training

import android.media.MediaMetadataRetriever
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** Requires dedicated solid-colour CFR fixtures in external files/export_smoke/{a,b}.mp4. */
@RunWith(AndroidJUnit4::class)
class VideoAnalysisExporterSmokeTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val fixtures get() = File(instrumentation.targetContext.getExternalFilesDir(null), "export_smoke")

    @Test fun single() = checkExport("single")
    @Test fun sideBySide() = checkExport("sideBySide")
    @Test fun overlay() = checkExport("overlay")
    @Test fun overlayWithSignalBeforeComparisonFile() = checkExport("overlay", clippedComparison = true)

    private class Reply : MethodChannel.Result {
        val done = CountDownLatch(1)
        val value = AtomicReference<Any?>()
        val error = AtomicReference<String?>()
        override fun success(result: Any?) { value.set(result); done.countDown() }
        override fun error(code: String, message: String?, details: Any?) {
            error.set("$code: $message"); done.countDown()
        }
        override fun notImplemented() { error.set("notImplemented"); done.countDown() }
        fun await() {
            assertTrue("Native method did not finish", done.await(90, TimeUnit.SECONDS))
        }
    }

    @Test fun realClipSingle() = checkExport("single", "real.mp4")
    @Test fun realClipSideBySide() = checkExport("sideBySide", "real.mp4")

    private fun checkExport(mode: String, primaryName: String = "a.mp4", clippedComparison: Boolean = false) {
        val primary = File(fixtures, primaryName)
        val comparison = File(fixtures, "b.mp4")
        assertTrue("Prepare synthetic a.mp4 fixture first", primary.isFile)
        assertTrue("Prepare synthetic b.mp4 fixture first", comparison.isFile)
        val originals = listOf(primary, comparison).map { it.length() to it.lastModified() }
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var exporter: VideoAnalysisExporter
            scenario.onActivity { exporter = VideoAnalysisExporter(it) }
            try {
                val args = mutableMapOf<String, Any>(
                    "primaryPath" to primary.absolutePath, "start" to .5,
                    "times" to listOf(.3, .8, 1.4), "primaryLabel" to "SMOKE A",
                    "mode" to mode, "opacity" to .35,
                )
                if (mode != "single") args.putAll(mapOf(
                    "comparisonPath" to comparison.absolutePath, "comparisonStart" to if (clippedComparison) -.2 else .7,
                    "comparisonCorrection" to if (clippedComparison) 0.0 else .2, "comparisonTimes" to listOf(.4, .9, 1.5),
                    "comparisonLabel" to "SMOKE B",
                ))
                val reply = Reply()
                instrumentation.runOnMainSync { assertTrue(exporter.handle(MethodCall("exportAnalysis", args), reply)) }
                reply.await()
                assertNull(reply.error.get(), reply.error.get())
                val output = File(reply.value.get() as String)
                assertTrue("Export file is empty", output.isFile && output.length() > 1024)
                assertNotEquals(primary.canonicalPath, output.canonicalPath)
                val metadata = MediaMetadataRetriever()
                try {
                    metadata.setDataSource(output.absolutePath)
                    val width = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)!!.toInt()
                    val height = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)!!.toInt()
                    assertTrue("Export exceeds Full HD bounds", max(width, height) <= 1920 && min(width, height) <= 1080)
                    assertTrue(width > 0 && height > 0)
                    assertEquals("Primary audio must survive export", "yes", metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO))
                    val duration = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toLong()
                    assertTrue("Export duration is implausible", duration >= 1000)
                    val sourceDurations = listOf(primary, comparison).map { source ->
                        val sourceMetadata = MediaMetadataRetriever()
                        try {
                            sourceMetadata.setDataSource(source.absolutePath)
                            sourceMetadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toLong()
                        } finally { sourceMetadata.release() }
                    }
                    val expectedDuration = if (mode == "single") sourceDurations[0]
                        else if (clippedComparison) min(sourceDurations[0] - 700, sourceDurations[1])
                        else min(sourceDurations[0] - 500, sourceDurations[1] - 900)
                    assertTrue("Export did not preserve the synchronized trim duration", abs(duration - expectedDuration) <= 250)
                    val frame = metadata.getFrameAtTime(1_200_000, MediaMetadataRetriever.OPTION_CLOSEST)
                    assertNotNull("Export cannot decode", frame)
                    frame!!
                    if (mode == "sideBySide" && primaryName == "a.mp4") {
                        val left = frame.getPixel(frame.width / 4, frame.height * 3 / 4)
                        val right = frame.getPixel(frame.width * 3 / 4, frame.height * 3 / 4)
                        assertTrue("Primary blue video must occupy the left cell", android.graphics.Color.blue(left) > android.graphics.Color.green(left) + 60)
                        assertTrue("Comparison green video must occupy the right cell", android.graphics.Color.green(right) > android.graphics.Color.blue(right) + 60)
                    }
                    var brightTextPixels = 0
                    var bottomTextPixels = 0
                    for (y in 0 until max(1, frame.height / 4)) {
                        for (x in 0 until frame.width) {
                            val pixel = frame.getPixel(x, y)
                            if (android.graphics.Color.red(pixel) > 170 && android.graphics.Color.green(pixel) > 170 && android.graphics.Color.blue(pixel) > 170) brightTextPixels++
                            val bottomPixel = frame.getPixel(x, frame.height - 1 - y)
                            if (android.graphics.Color.red(bottomPixel) > 170 && android.graphics.Color.green(bottomPixel) > 170 && android.graphics.Color.blue(bottomPixel) > 170) bottomTextPixels++
                        }
                    }
                    frame.recycle()
                    if (clippedComparison) {
                        val first = metadata.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST)!!
                        val image = File(instrumentation.targetContext.filesDir, "clipped-signal-overlay-first-frame.png")
                        image.outputStream().use { stream -> first.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, stream) }
                        assertTimerAtStart(first, .2, bottom = false)
                        assertTimerAtStart(first, .2, bottom = true)
                        first.recycle()
                    }
                    if (mode == "overlay") assertTrue("Comparison HUD must remain readable at the bottom", bottomTextPixels > 20)
                    assertTrue("Burned-in white HUD text missing on solid-colour fixture", brightTextPixels > 20)
                    instrumentation.sendStatus(0, android.os.Bundle().apply {
                        putString("stream", "PACE_EXPORT_SMOKE mode=$mode path=${output.absolutePath} bytes=${output.length()} size=${width}x$height durationMs=$duration hudPixels=$brightTextPixels bottomHudPixels=$bottomTextPixels\n")
                    })
                } finally { metadata.release() }
                assertEquals("Source files must remain unchanged", originals, listOf(primary, comparison).map { it.length() to it.lastModified() })
            } finally { instrumentation.runOnMainSync { exporter.dispose() } }
        }
    }

    private fun assertTimerAtStart(frame: android.graphics.Bitmap, seconds: Double, bottom: Boolean) {
        val expected = android.graphics.Bitmap.createBitmap(frame.width, frame.height, android.graphics.Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(expected)
        val size = (frame.width * .034f).coerceIn(16f, 64f)
        val pad = size * .45f
        val top = if (bottom) frame.height - size * 3.4f else 0f
        val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            color = android.graphics.Color.WHITE
            typeface = android.graphics.Typeface.create(android.graphics.Typeface.MONOSPACE, android.graphics.Typeface.BOLD)
            textSize = size
        }
        val timer = String.format(java.util.Locale.US, "%.2f s", seconds)
        canvas.drawText(timer, pad, top + size * 2.55f, paint)
        var matches = 0
        var pixels = 0
        val right = (pad + paint.measureText(timer)).toInt().coerceAtMost(frame.width)
        for (y in max(0, (top + size * 1.5f).toInt()) until min(frame.height, (top + size * 2.65f).toInt())) {
            for (x in pad.toInt() until right) {
                if (android.graphics.Color.alpha(expected.getPixel(x, y)) > 245) {
                    pixels++
                    val actual = frame.getPixel(x, y)
                    if (minOf(android.graphics.Color.red(actual), android.graphics.Color.green(actual), android.graphics.Color.blue(actual)) > 170) matches++
                }
            }
        }
        expected.recycle()
        assertTrue("Missing timer glyphs in clipped-signal HUD", pixels > 20)
        assertTrue("Clipped-signal HUD must start at0.20s (bottom=$bottom, matches=$matches/$pixels)", matches.toDouble() / pixels >= .95)
    }

    @Test fun cancelBeforeEncoderStarts() {
        val primary = File(fixtures, "a.mp4")
        assertTrue("Prepare synthetic a.mp4 fixture first", primary.isFile)
        val directory = File(instrumentation.targetContext.filesDir, "analysis_exports")
        val before = directory.list()?.toSet() ?: emptySet<String>()
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var exporter: VideoAnalysisExporter
            scenario.onActivity { exporter = VideoAnalysisExporter(it) }
            try {
                val reply = Reply()
                instrumentation.runOnMainSync {
                    exporter.handle(MethodCall("exportAnalysis", mapOf("primaryPath" to primary.absolutePath, "start" to .5, "times" to listOf(.3))), reply)
                    exporter.cancel()
                }
                reply.await()
                assertTrue("Cancellation must report an error", reply.error.get()?.contains("cancelled") == true)
                assertNull(reply.value.get())
                assertEquals("Cancelled export left a partial file", before, directory.list()?.toSet() ?: emptySet<String>())
            } finally { instrumentation.runOnMainSync { exporter.dispose() } }
        }
    }
}
