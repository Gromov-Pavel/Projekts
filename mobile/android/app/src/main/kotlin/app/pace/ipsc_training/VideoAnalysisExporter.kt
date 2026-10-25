package app.pace.ipsc_training

import android.app.Activity
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.Typeface
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.media3.common.Effect
import androidx.media3.common.VideoCompositorSettings
import androidx.media3.common.OverlaySettings
import androidx.media3.common.util.Size
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.effect.CanvasOverlay
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.Presentation
import androidx.media3.transformer.*
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors
import kotlin.math.*

/** All exports use a new app-private file; original media is read only. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class VideoAnalysisExporter(private val activity: Activity) {
    private val worker = Executors.newSingleThreadExecutor()
    private var transformer: Transformer? = null
    private var pending: MethodChannel.Result? = null
    private var output: File? = null
    private var disposed = false

    private data class Info(val width: Int, val height: Int, val duration: Double, val frameRate: Double?)
    private data class Run(val path: String, val start: Double, val times: List<Double>, val label: String)

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "exportAnalysis" -> export(call, result)
            "cancelExportAnalysis" -> { cancel(); result.success(null) }
            "videoInfo" -> {
                val path = call.argument<String>("path")
                if (path == null) result.error("videoInfo", "Video path missing", null)
                else worker.execute {
                    try {
                        val info = readInfo(path)
                        activity.runOnUiThread { if (!disposed) result.success(mapOf("duration" to info.duration, "frameRate" to info.frameRate)) }
                    } catch (error: Exception) {
                        activity.runOnUiThread { if (!disposed) result.error("videoInfo", error.message, null) }
                    }
                }
            }
            else -> return false
        }
        return true
    }

    private fun readRun(call: MethodCall, comparison: Boolean = false): Run {
        val path = call.argument<String>(if (comparison) "comparisonPath" else "primaryPath")
        require(!path.isNullOrBlank() && File(path).isFile) { "Video file is missing" }
        val start = call.argument<Number>(if (comparison) "comparisonStart" else "start")?.toDouble() ?: 0.0
        require(start.isFinite()) { "Invalid start time" }
        val raw = call.argument<List<*>>(if (comparison) "comparisonTimes" else "times") ?: emptyList<Any>()
        require(raw.size <= 10000) { "Too many shots" }
        val times = raw.map { require(it is Number) { "Invalid shot time" }; it.toDouble() }
        require(times.all { it.isFinite() && it >= 0 } && times.zipWithNext().all { it.second > it.first }) { "Shot times must increase" }
        val label = call.argument<String>(if (comparison) "comparisonLabel" else "primaryLabel") ?: "PACE"
        require(label.length <= 120) { "Video label is too long" }
        return Run(path!!, start, times, label.replace('\n', ' '))
    }

    private fun export(call: MethodCall, result: MethodChannel.Result) {
        if (pending != null) { result.error("exportBusy", "An export is already running", null); return }
        try {
            check(!disposed) { "Exporter is closed" }
            val mode = call.argument<String>("mode") ?: "single"
            require(mode in listOf("single", "sideBySide", "overlay")) { "Unknown export mode" }
            val runs = if (mode == "single") listOf(readRun(call)) else listOf(readRun(call), readRun(call, true))
            val opacity = call.argument<Number>("opacity")?.toDouble() ?: .5
            require(opacity.isFinite() && opacity in 0.0..1.0) { "Invalid comparison opacity" }
            val correction = call.argument<Number>("comparisonCorrection")?.toDouble() ?: 0.0
            require(correction.isFinite()) { "Invalid comparison correction" }
            pending = result
            worker.execute {
                try {
                    val infos = runs.map { run ->
                        readInfo(run.path).also { info ->
                            require(run.start < info.duration && (run.times.lastOrNull() ?: 0.0) + run.start <= info.duration + .1) { "Shot markers are outside the video" }
                        }
                    }
                    activity.runOnUiThread {
                        if (pending === result && !disposed) {
                            try { start(runs, infos, mode, opacity, correction) } catch (error: Exception) { fail(error.message ?: "Export failed") }
                        }
                    }
                } catch (error: Exception) {
                    activity.runOnUiThread { if (pending === result) fail(error.message ?: "Video could not be opened") }
                }
            }
        } catch (error: Exception) { result.error("exportAnalysis", error.message, null) }
    }

    private fun start(runs: List<Run>, infos: List<Info>, mode: String, opacity: Double, correction: Double) {
        val directory = File(activity.filesDir, "analysis_exports")
        check(directory.isDirectory || directory.mkdirs()) { "Export directory unavailable" }
        val file = File(directory, "pace-${UUID.randomUUID()}.mp4")
        output = file
        val paired = runs.size == 2
        val timerStarts = runs.mapIndexed { index, run -> run.start + if (index == 1) correction else 0.0 }
        require(timerStarts.all { it.isFinite() }) { "Invalid corrected start time" }
        // Start where both files have actual frames, retaining elapsed time since the missing signal.
        val lead = if (paired) max(0.0, -timerStarts.min()) else 0.0
        val trimStarts = if (paired) timerStarts.map { it + lead } else listOf(0.0)
        require(trimStarts.all { it.isFinite() && it >= 0 }) { "Invalid synchronized start time" }
        val duration = if (paired) runs.indices.minOf { infos[it].duration - trimStarts[it] } else infos[0].duration
        require(duration >= .01) { "Comparison correction leaves no video" }
        val portrait = infos[0].height > infos[0].width
        val boxWidth = if (mode == "sideBySide") 960 else if (portrait) 1080 else 1920
        val boxHeight = if (mode == "sideBySide") 1080 else if (portrait) 1920 else 1080
        val sizes = infos.map { info ->
            val scale = minOf(1.0, boxWidth.toDouble() / info.width, boxHeight.toDouble() / info.height)
            Size(max(2, floor(info.width * scale / 2).toInt() * 2),
                max(2, floor(info.height * scale / 2).toInt() * 2))
        }
        val sequences = runs.mapIndexed { index, run ->
            val media = MediaItem.Builder().setUri(Uri.fromFile(File(run.path)))
            if (paired) media.setClippingConfiguration(MediaItem.ClippingConfiguration.Builder()
                .setStartPositionMs((trimStarts[index] * 1000).roundToLong())
                .setEndPositionMs(((trimStarts[index] + duration) * 1000).roundToLong()).build())
            val videoEffects = mutableListOf<Effect>(
                Presentation.createForWidthAndHeight(sizes[index].width, sizes[index].height, Presentation.LAYOUT_SCALE_TO_FIT),
            )
            if (mode != "overlay") videoEffects.add(OverlayEffect(listOf(ShotOverlay(run, if (paired) run.start - trimStarts[index] else run.start))))
            val effects = Effects(emptyList(), videoEffects)
            val item = EditedMediaItem.Builder(media.build()).setEffects(effects)
                .setRemoveAudio(index > 0).build()
            EditedMediaItemSequence.Builder(item).build()
        }
        val compositionBuilder = Composition.Builder(sequences)
            .setHdrMode(Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL)
        if (paired) {
            val outputWidth = if (mode == "sideBySide") sizes.sumOf { it.width } else sizes.maxOf { it.width }
            val outputHeight = sizes.maxOf { it.height }
            compositionBuilder.setVideoCompositorSettings(object : VideoCompositorSettings {
                override fun getOutputSize(inputSizes: MutableList<Size>): Size = Size(outputWidth, outputHeight)
                override fun getOverlaySettings(inputId: Int, presentationTimeUs: Long): OverlaySettings {
                    val settings = StaticOverlaySettings.Builder()
                    if (mode == "sideBySide") {
                        val x = if (inputId == 0) -1f + sizes[0].width.toFloat() / outputWidth
                            else 1f - sizes[1].width.toFloat() / outputWidth
                        settings.setBackgroundFrameAnchor(x, 0f)
                    } else if (inputId == 0) {
                        // The compositor draws primary on top, so comparison opacity fades primary.
                        settings.setAlphaScale((1.0 - opacity).toFloat())
                    }
                    return settings.build()
                }
            })
        }
        if (mode == "overlay") {
            // Draw both HUDs after blending, so opacity never fades or stacks the text.
            compositionBuilder.setEffects(Effects(emptyList(), listOf(OverlayEffect(listOf(
                ShotOverlay(runs[0], -lead, halfWidth = true), ShotOverlay(runs[1], -lead - correction, right = true, halfWidth = true),
            )))))
        }
        val composition = compositionBuilder.build()
        val current = Transformer.Builder(activity).setVideoMimeType(MimeTypes.VIDEO_H264)
            .setAudioMimeType(MimeTypes.AUDIO_AAC).setUsePlatformDiagnostics(false)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    if (output !== file) return
                    if (!file.isFile || file.length() == 0L || exportResult.videoFrameCount <= 0 ||
                        exportResult.width <= 0 || exportResult.height <= 0 || max(exportResult.width, exportResult.height) > 1920 ||
                        min(exportResult.width, exportResult.height) > 1080) {
                        fail("Encoder produced no valid Full HD video"); return
                    }
                    val callback = pending
                    pending = null; transformer = null; output = null
                    callback?.success(file.absolutePath)
                }
                override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                    if (output === file) fail(exportException.message ?: "Video encoding failed")
                }
            }).build()
        transformer = current
        current.start(composition, file.absolutePath)
    }

    private class ShotOverlay(private val run: Run, private val start: Double, private val right: Boolean = false, private val halfWidth: Boolean = false) : CanvasOverlay(true) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD) }
        override fun onDraw(canvas: Canvas, presentationTimeUs: Long) {
            canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
            val elapsed = presentationTimeUs / 1e6 - start
            var shot = run.times.binarySearch(elapsed)
            shot = if (shot >= 0) shot + 1 else -shot - 1
            val split = if (shot > 0) run.times[shot - 1] - if (shot > 1) run.times[shot - 2] else 0.0 else 0.0
            val size = (canvas.width * .034f).coerceIn(16f, 64f)
            paint.textSize = size
            val pad = size * .45f
            val width = (if (halfWidth) canvas.width / 2f else canvas.width.toFloat()) - pad * 2
            val top = canvas.height - size * 4.4f
            paint.color = Color.WHITE
            paint.setShadowLayer(size * .1f, 1f, 1f, Color.BLACK)
            fun text(value: String, baseline: Float, scale: Float) {
                paint.textSize = size * scale
                paint.textSize *= min(1f, width / max(1f, paint.measureText(value)))
                val x = if (right) canvas.width - pad - paint.measureText(value) else pad
                canvas.drawText(value, x, top + size * baseline, paint)
            }
            val label = android.text.TextUtils.ellipsize(run.label, android.text.TextPaint(paint), width, android.text.TextUtils.TruncateAt.END).toString()
            text(label, .95f, .8f)
            val timer = if (shot == 0) "—" else String.format(Locale.US, "%.2f s", run.times[shot - 1])
            text(timer, 2.5f, 1.5f)
            val splitText = if (shot == 0) "—" else String.format(Locale.US, "%.2f", split)
            text("#$shot/${run.times.size}  SPLIT $splitText", 3.7f, .8f)
        }
    }

    private fun readInfo(path: String): Info {
        require(File(path).isFile) { "Video file is missing" }
        val metadata = MediaMetadataRetriever()
        try {
            metadata.setDataSource(path)
            var width = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            var height = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            val rotation = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            if (rotation % 180 != 0) { val swap = width; width = height; height = swap }
            val duration = (metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toDoubleOrNull() ?: 0.0) / 1000
            require(width > 0 && height > 0 && duration > 0 && duration <= 600) { "Video must be valid and at most 10 minutes" }
            val extractor = MediaExtractor()
            var frameRate: Double? = null
            try {
                extractor.setDataSource(path)
                for (index in 0 until extractor.trackCount) {
                    val format = extractor.getTrackFormat(index)
                    if (format.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                        if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                            frameRate = try { format.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble() }
                                catch (_: ClassCastException) { format.getFloat(MediaFormat.KEY_FRAME_RATE).toDouble() }
                        }
                        break
                    }
                }
            } finally { extractor.release() }
            return Info(width, height, duration, frameRate?.takeIf { it.isFinite() && it > 0 })
        } finally { metadata.release() }
    }

    private fun fail(message: String) {
        val callback = pending
        pending = null
        val current = transformer
        val partial = output
        transformer = null; output = null
        current?.cancel()
        partial?.delete()
        callback?.error("exportAnalysis", message, null)
    }

    fun cancel() { if (pending != null) fail("Export cancelled") }
    fun dispose() { disposed = true; cancel(); worker.shutdownNow() }
}
