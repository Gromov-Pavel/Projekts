package app.pace.ipsc_training

import android.app.Activity
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.media.metrics.LogSessionId
import android.view.Surface
import androidx.media3.common.Format
import androidx.media3.common.util.Clock
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.effect.FrameDropEffect
import androidx.media3.effect.Presentation
import androidx.media3.transformer.*
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.Executors
import kotlin.math.*

/** Playback proxies retain the complete original timeline and contain no analysis overlay. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class VideoPreview(private val activity: Activity) {
    private data class Info(val width: Int, val height: Int, val duration: Double,
        val frameRate: Double?, val mime: String, val audioMime: String?)
    private class Job(val path: String, val result: MethodChannel.Result) {
        @Volatile var cancelled = false
        var temporary: File? = null
    }
    private val worker = Executors.newSingleThreadExecutor()
    private val queue = ArrayDeque<Job>()
    private var current: Job? = null
    private var transformer: Transformer? = null
    private var disposed = false

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "prepareVideoPreview" -> {
                val path = call.argument<String>("path")
                if (disposed || path.isNullOrBlank()) result.error("videoPreview", "Video path missing or preview closed", null)
                else { queue.add(Job(path, result)); next() }
            }
            "cancelVideoPreview" -> { cancel(); result.success(null) }
            else -> return false
        }
        return true
    }

    private fun next() {
        if (disposed || current != null || queue.isEmpty()) return
        val job = queue.removeFirst()
        current = job
        worker.execute {
            try {
                val source = File(job.path).canonicalFile
                require(source.isFile) { "Source video is missing" }
                val identity = identity(source)
                val info = inspect(source)
                val portrait = info.height > info.width
                val boxWidth = if (portrait) 720 else 1280
                val boxHeight = if (portrait) 1280 else 720
                if (info.mime == MimeTypes.VIDEO_H264 && info.width <= boxWidth && info.height <= boxHeight &&
                    info.frameRate != null && info.frameRate <= 30.05) {
                    activity.runOnUiThread { if (current === job) complete(job, source, info) }
                    return@execute
                }
                val directory = File(activity.cacheDir, "video_previews")
                check(directory.isDirectory || directory.mkdirs()) { "Preview cache unavailable" }
                val cached = File(directory, "$identity.mp4")
                if (cached.isFile) {
                    val existing = try { inspect(cached, measureRate = true) } catch (_: Exception) { null }
                    if (existing != null && valid(existing, info, boxWidth, boxHeight)) {
                        activity.runOnUiThread { if (current === job) complete(job, cached, existing) }
                        return@execute
                    }
                    check(cached.delete()) { "Invalid cached preview could not be removed" }
                }
                activity.runOnUiThread {
                    if (current === job && !job.cancelled) {
                        try { transcode(job, source, identity, info, cached, boxWidth, boxHeight) }
                        catch (error: Exception) { fail(job, error.message ?: "Preview encoder unavailable") }
                    }
                }
            } catch (error: Exception) {
                activity.runOnUiThread { if (current === job) fail(job, error.message ?: "Preview could not be prepared") }
            }
        }
    }

    private fun transcode(job: Job, source: File, sourceIdentity: String, info: Info, cached: File, boxWidth: Int, boxHeight: Int) {
        val scale = minOf(1.0, boxWidth.toDouble() / info.width, boxHeight.toDouble() / info.height)
        val width = max(2, floor(info.width * scale / 2).toInt() * 2)
        val height = max(2, floor(info.height * scale / 2).toInt() * 2)
        val temporary = File(cached.parentFile, "${cached.nameWithoutExtension}-${UUID.randomUUID()}.partial.mp4")
        job.temporary = temporary
        val targetRate = min(30.0, info.frameRate ?: 30.0).toFloat()
        val effects = Effects(emptyList(), listOf(
            Presentation.createForWidthAndHeight(width, height, Presentation.LAYOUT_SCALE_TO_FIT),
            FrameDropEffect.createDefaultFrameDropEffect(targetRate),
        ))
        val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(source))).setEffects(effects).build()
        val composition = Composition.Builder(EditedMediaItemSequence.Builder(item).build())
            .setHdrMode(Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL).build()
        val decoderFactory = object : Codec.DecoderFactory {
            private val audio = DefaultDecoderFactory.Builder(activity).setEnableDecoderFallback(true).build()
            override fun createForAudioDecoding(format: Format, logSessionId: LogSessionId?): Codec =
                audio.createForAudioDecoding(format, logSessionId)
            override fun createForVideoDecoding(format: Format, outputSurface: Surface,
                requestSdrToneMapping: Boolean, logSessionId: LogSessionId?): Codec {
                // Offline decoding need not run at source fps; profile, level and dimensions still must fit.
                val capabilityFormat = format.buildUpon().setFrameRate(Format.NO_VALUE.toFloat()).build()
                val selector = MediaCodecSelector { mime, secure, tunneled ->
                    MediaCodecSelector.DEFAULT.getDecoderInfos(mime, secure, tunneled)
                        .filter { decoder -> try { decoder.isFormatSupported(activity.applicationContext, capabilityFormat) } catch (_: Exception) { false } }
                        .sortedBy { if (it.hardwareAccelerated) 0 else 1 }
                }
                return DefaultDecoderFactory.Builder(activity).setEnableDecoderFallback(true)
                    .setMediaCodecSelector(selector).setListener { name, exceptions ->
                        android.util.Log.i("PacePreview", "Decoder=$name fallbackAttempts=${exceptions.size}")
                    }.build().createForVideoDecoding(format, outputSurface, requestSdrToneMapping, logSessionId)
            }
        }
        val assets = DefaultAssetLoaderFactory(activity, decoderFactory, Clock.DEFAULT, null)
        val encoder = Transformer.Builder(activity).setAssetLoaderFactory(assets).setVideoMimeType(MimeTypes.VIDEO_H264)
            .setAudioMimeType(MimeTypes.AUDIO_AAC).setUsePlatformDiagnostics(false)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    if (current !== job) return
                    transformer = null
                    worker.execute {
                        try {
                            check(!job.cancelled) { "Preview cancelled" }
                            val preview = inspect(temporary, measureRate = true)
                            check(exportResult.videoFrameCount > 0 && valid(preview, info, boxWidth, boxHeight)) {
                                "Encoder produced an invalid preview"
                            }
                            check(identity(source) == sourceIdentity) { "Source video changed while preparing preview" }
                            check(!job.cancelled) { "Preview cancelled" }
                            // renameTo is atomic on this same cache filesystem; source is never a destination.
                            check(temporary.renameTo(cached)) { "Preview cache could not be committed" }
                            activity.runOnUiThread { if (current === job) complete(job, cached, preview) }
                        } catch (error: Exception) {
                            temporary.delete()
                            activity.runOnUiThread { if (current === job) fail(job, error.message ?: "Preview validation failed") }
                        }
                    }
                }
                override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                    if (current === job) {
                        val unsupported = exportException.errorCode in listOf(
                            ExportException.ERROR_CODE_DECODER_INIT_FAILED,
                            ExportException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
                        )
                        if (unsupported) fail(job,
                            "Устройство не смогло открыть исходное видео доступными декодерами. Подготовьте H.264/AAC 720p 30 fps на компьютере и загрузите копию.",
                            "videoPreviewUnsupported")
                        else fail(job, exportException.message ?: "Preview encoding failed")
                    }
                }
            }).build()
        transformer = encoder
        encoder.start(composition, temporary.absolutePath)
    }

    private fun identity(file: File): String {
        val source = "preview-v1|${file.canonicalPath}|${file.length()}|${file.lastModified()}"
        return MessageDigest.getInstance("SHA-256").digest(source.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 255) }
    }

    private fun valid(preview: Info, original: Info, boxWidth: Int, boxHeight: Int) =
        preview.mime == MimeTypes.VIDEO_H264 && preview.width <= boxWidth && preview.height <= boxHeight &&
        preview.width <= original.width && preview.height <= original.height &&
        preview.frameRate != null && preview.frameRate <= 30.5 && abs(preview.duration - original.duration) <= .25 &&
        (original.audioMime == null || preview.audioMime == MimeTypes.AUDIO_AAC)

    private fun inspect(file: File, measureRate: Boolean = false): Info {
        require(file.isFile && file.length() > 0) { "Video file is missing or empty" }
        val metadata = MediaMetadataRetriever()
        val extractor = MediaExtractor()
        try {
            metadata.setDataSource(file.absolutePath)
            var width = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            var height = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            val rotation = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            if (rotation % 180 != 0) { val swap = width; width = height; height = swap }
            val duration = (metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toDoubleOrNull() ?: 0.0) / 1000
            require(width >= 2 && height >= 2 && duration > 0 && duration <= 600) { "Preview requires a valid video up to 10 minutes" }
            extractor.setDataSource(file.absolutePath)
            var videoTrack = -1
            var mime = ""
            var audioMime: String? = null
            var rate: Double? = null
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val type = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (type.startsWith("audio/")) audioMime = type
                if (type.startsWith("video/") && videoTrack == -1) {
                    videoTrack = index; mime = type
                    if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                        rate = try { format.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble() }
                            catch (_: ClassCastException) { format.getFloat(MediaFormat.KEY_FRAME_RATE).toDouble() }
                    }
                }
            }
            require(videoTrack >= 0) { "Video track is missing" }
            if (measureRate) {
                extractor.selectTrack(videoTrack)
                var first = -1L
                var last = -1L
                var count = 0
                while (count < 301 && extractor.sampleTime >= 0) {
                    val at = extractor.sampleTime
                    if (count == 0) first = at
                    last = max(last, at); count++
                    if (!extractor.advance()) break
                }
                if (count > 1 && last > first) rate = (count - 1) * 1e6 / (last - first)
            }
            return Info(width, height, duration, rate?.takeIf { it.isFinite() && it > 0 }, mime, audioMime)
        } finally { extractor.release(); metadata.release() }
    }

    private fun complete(job: Job, file: File, info: Info) {
        if (current !== job) return
        current = null
        job.temporary = null
        job.result.success(mapOf("path" to file.absolutePath, "width" to info.width, "height" to info.height,
            "frameRate" to info.frameRate?.let { min(30.0, it) }))
        next()
    }

    private fun fail(job: Job, message: String, code: String = "videoPreview") {
        if (current !== job) return
        current = null
        job.cancelled = true
        val encoder = transformer; transformer = null
        encoder?.cancel()
        job.temporary?.delete(); job.temporary = null
        job.result.error(code, message, null)
        next()
    }

    fun cancel() {
        val waiting = queue.toList()
        queue.clear()
        waiting.forEach { it.cancelled = true; it.result.error("videoPreview", "Preview cancelled", null) }
        current?.let { fail(it, "Preview cancelled") }
    }

    fun dispose() { disposed = true; cancel(); worker.shutdownNow() }
}
