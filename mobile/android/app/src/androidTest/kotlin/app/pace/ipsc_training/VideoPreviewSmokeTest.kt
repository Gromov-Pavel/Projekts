package app.pace.ipsc_training

import android.graphics.Bitmap
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Assume.assumeFalse
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.*

/** Requires two real short 4K HEVC60 excerpts; never generates substitute videos. */
@RunWith(AndroidJUnit4::class)
class VideoPreviewSmokeTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val fixtures get() = File(instrumentation.targetContext.getExternalFilesDir(null), "preview_smoke")

    private class Reply : MethodChannel.Result {
        val done = CountDownLatch(1)
        var value: Any? = null
        var error: String? = null
        override fun success(result: Any?) { value = result; done.countDown() }
        override fun error(code: String, message: String?, details: Any?) { error = "$code: $message"; done.countDown() }
        override fun notImplemented() { error = "notImplemented"; done.countDown() }
        fun await(): Map<*, *> {
            assertTrue("Preview did not finish within 180s", done.await(180, TimeUnit.SECONDS))
            assertNull(error, error)
            return value as Map<*, *>
        }
    }

    @Test fun twoRealHevc4kPreviewsRetainTimelineAndCache() {
        val args = InstrumentationRegistry.getArguments()
        val originals = listOf(
            File(args.getString("previewPrimary") ?: File(fixtures, "a.mp4").absolutePath),
            File(args.getString("previewComparison") ?: File(fixtures, "b.mp4").absolutePath),
        )
        val hashes = originals.map { source ->
            assertTrue("Prepare real HEVC4K60 excerpt ${source.absolutePath}", source.isFile)
            assertHeavyHevc(source)
            digest(source)
        }
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var preview: VideoPreview
            scenario.onActivity { preview = VideoPreview(it) }
            try {
                val replies = originals.map { Reply() }
                instrumentation.runOnMainSync {
                    originals.zip(replies).forEach { (source, reply) ->
                        assertTrue(preview.handle(MethodCall("prepareVideoPreview", mapOf("path" to source.absolutePath)), reply))
                    }
                }
                val prepared = replies.map { it.await() }
                val outputTimes = mutableListOf<Long>()
                prepared.forEachIndexed { index, result ->
                    val file = File(result["path"] as String)
                    assertNotEquals("Heavy input must not be reused", originals[index].canonicalPath, file.canonicalPath)
                    assertTrue(file.isFile && file.length() > 1024)
                    assertTrue("Unexpected preview fps", (result["frameRate"] as Number).toDouble() <= 30)
                    inspectPreview(originals[index], file, result)
                    outputTimes.add(file.lastModified())
                    instrumentation.sendStatus(0, android.os.Bundle().apply {
                        putString("stream", "PACE_PREVIEW_SMOKE source=${originals[index].name} path=${file.absolutePath} width=${result["width"]} height=${result["height"]} fps=${result["frameRate"]} bytes=${file.length()}\n")
                    })
                }
                originals.forEachIndexed { index, source ->
                    val cached = Reply()
                    instrumentation.runOnMainSync { preview.handle(MethodCall("prepareVideoPreview", mapOf("path" to source.absolutePath)), cached) }
                    val reused = cached.await()
                    assertEquals("Cache path changed", prepared[index]["path"], reused["path"])
                    assertEquals("Cache was needlessly re-encoded", outputTimes[index], File(reused["path"] as String).lastModified())
                    assertEquals("Source was modified", hashes[index], digest(source))
                }
            } finally { instrumentation.runOnMainSync { preview.dispose() } }
        }
    }

    @Test fun compatibleCopiesReuseAndDecode() = checkCompatibleCopies()

    @Test fun unsupportedSourceDoesNotBreakCompatibleCopies() {
        val source = File(InstrumentationRegistry.getArguments().getString("previewPrimary")
            ?: File(fixtures, "a.mp4").absolutePath)
        assertTrue("Prepare real4KHEVC fixture", source.isFile)
        assertHeavyHevc(source)
        val extractor = MediaExtractor()
        val capabilityFormat: MediaFormat
        try {
            extractor.setDataSource(source.absolutePath)
            val input = (0 until extractor.trackCount).map { extractor.getTrackFormat(it) }
                .first { it.getString(MediaFormat.KEY_MIME) == "video/hevc" }
            capabilityFormat = MediaFormat.createVideoFormat("video/hevc",
                input.getInteger(MediaFormat.KEY_WIDTH), input.getInteger(MediaFormat.KEY_HEIGHT))
            // Offline decoding may be slow; do not confuse unsupported60fps with unsupported format.
            for (key in listOf(MediaFormat.KEY_PROFILE, MediaFormat.KEY_LEVEL, MediaFormat.KEY_COLOR_TRANSFER,
                MediaFormat.KEY_COLOR_STANDARD, MediaFormat.KEY_COLOR_RANGE)) {
                if (input.containsKey(key)) capabilityFormat.setInteger(key, input.getInteger(key))
            }
        } finally { extractor.release() }
        val supported = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.any { codec ->
            !codec.isEncoder && codec.supportedTypes.any { it.equals("video/hevc", true) } &&
                try { codec.getCapabilitiesForType("video/hevc").isFormatSupported(capabilityFormat) }
                catch (_: Exception) { false }
        }
        assumeFalse("Device declares a suitable decoder; unsupported outcome is not expected here", supported)
        checkCompatibleCopies(source)
    }

    private fun checkCompatibleCopies(unsupportedSource: File? = null) {
        val copies = listOf(File(fixtures, "compatible-a.mp4"), File(fixtures, "compatible-b.mp4"))
        val originals = copies.map { source ->
            assertTrue("Prepare real compatible H264720/30 copy ${source.absolutePath}", source.isFile)
            Triple(source.length(), source.lastModified(), digest(source))
        }
        val cache = File(instrumentation.targetContext.cacheDir, "video_previews")
        val partialsBefore = cache.list()?.filter { it.endsWith(".partial.mp4") }?.toSet() ?: emptySet<String>()
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var preview: VideoPreview
            scenario.onActivity { preview = VideoPreview(it) }
            try {
                val bad = if (unsupportedSource != null) Reply() else null
                val replies = copies.map { Reply() }
                instrumentation.runOnMainSync {
                    if (bad != null) preview.handle(MethodCall("prepareVideoPreview", mapOf("path" to unsupportedSource!!.absolutePath)), bad)
                    copies.zip(replies).forEach { (source, reply) ->
                        preview.handle(MethodCall("prepareVideoPreview", mapOf("path" to source.absolutePath)), reply)
                    }
                }
                if (bad != null) {
                    assertTrue("Unsupported source did not finish", bad.done.await(180, TimeUnit.SECONDS))
                    assertTrue("Unsupported source must return a qualified error", bad.error?.startsWith("videoPreviewUnsupported:") == true)
                    assertNull("Unsupported source must not return fake success", bad.value)
                }
                copies.zip(replies).forEachIndexed { index, (source, reply) ->
                    val result = reply.await()
                    assertEquals("Compatible copy should be reused", source.canonicalPath, File(result["path"] as String).canonicalPath)
                    assertTrue("Returned nominal fps must not exceed30", (result["frameRate"] as Number).toDouble() in 1.0..30.0)
                    inspectPreview(source, source, result)
                    assertEquals("Compatible source changed", originals[index], Triple(source.length(), source.lastModified(), digest(source)))
                    instrumentation.sendStatus(0, android.os.Bundle().apply {
                        putString("stream", "PACE_COMPATIBLE_COPY path=${result["path"]} width=${result["width"]} height=${result["height"]} fps=${result["frameRate"]} reused=true afterUnsupported=${bad != null}\n")
                    })
                }
                assertEquals("Unsupported preparation left a partial file", partialsBefore,
                    cache.list()?.filter { it.endsWith(".partial.mp4") }?.toSet() ?: emptySet<String>())
            } finally { instrumentation.runOnMainSync { preview.dispose() } }
        }
    }

    @Test fun cancelQueuedPreviewsAndRejectMissingFile() {
        val source = File(fixtures, "a.mp4")
        assertTrue("Prepare real a.mp4 fixture", source.isFile)
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var preview: VideoPreview
            scenario.onActivity { preview = VideoPreview(it) }
            try {
                val first = Reply(); val second = Reply()
                instrumentation.runOnMainSync {
                    preview.handle(MethodCall("prepareVideoPreview", mapOf("path" to source.absolutePath)), first)
                    preview.handle(MethodCall("prepareVideoPreview", mapOf("path" to source.absolutePath)), second)
                    preview.cancel()
                }
                for (reply in listOf(first, second)) {
                    assertTrue(reply.done.await(5, TimeUnit.SECONDS))
                    assertTrue(reply.error?.contains("cancelled") == true)
                    assertNull(reply.value)
                }
                val missing = Reply()
                instrumentation.runOnMainSync { preview.handle(MethodCall("prepareVideoPreview", mapOf("path" to File(fixtures, "missing-${System.nanoTime()}.mp4").absolutePath)), missing) }
                assertTrue(missing.done.await(10, TimeUnit.SECONDS))
                assertTrue(missing.error?.contains("missing") == true)
            } finally { instrumentation.runOnMainSync { preview.dispose() } }
        }
    }

    @Test fun media3RuntimeMatchesCompiledApi() {
        // Reflection avoids the inlined VERSION constant and fails safely before a decoder thread starts.
        val runtimeVersion = Class.forName("androidx.media3.common.MediaLibraryInfo").getField("VERSION").get(null)
        assertEquals("Installed base APK has a different Media3 version", "1.9.2", runtimeVersion)
        val support = Class.forName("androidx.media3.exoplayer.mediacodec.MediaCodecInfo").getMethod(
            "isFormatSupported", android.content.Context::class.java, androidx.media3.common.Format::class.java,
        )
        assertEquals(java.lang.Boolean.TYPE, support.returnType)
        instrumentation.sendStatus(0, android.os.Bundle().apply { putString("stream", "PACE_MEDIA3_RUNTIME version=$runtimeVersion contextualCodecApi=true\n") })
    }

    @Test fun reportPlatformHevcDecoderCapabilities() {
        val fixture = File(InstrumentationRegistry.getArguments().getString("previewPrimary")
            ?: File(fixtures, "a.mp4").absolutePath)
        var input: MediaFormat? = null
        if (fixture.isFile) {
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(fixture.absolutePath)
                input = (0 until extractor.trackCount).map { extractor.getTrackFormat(it) }
                    .firstOrNull { it.getString(MediaFormat.KEY_MIME) == "video/hevc" }
            } finally { extractor.release() }
        }
        for (codec in MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos) {
            if (codec.isEncoder || codec.supportedTypes.none { it.equals("video/hevc", true) }) continue
            val line = try {
                val caps = codec.getCapabilitiesForType("video/hevc")
                val video = checkNotNull(caps.videoCapabilities)
                val profiles = caps.profileLevels.joinToString { "${it.profile}:${it.level}" }
                val supportsSource = input?.let { caps.isFormatSupported(it) }
                "codec=${codec.name} software=${codec.isSoftwareOnly} hardware=${codec.isHardwareAccelerated} " +
                    "profiles=$profiles sizes=${video.supportedWidths}x${video.supportedHeights} " +
                    "4kSize=${video.isSizeSupported(3840, 2160)} 4k60=${video.areSizeAndRateSupported(3840, 2160, 60.0)} " +
                    "sourceSupported=$supportsSource input=$input"
            } catch (error: Exception) { "codec=${codec.name} capabilityError=${error.message}" }
            instrumentation.sendStatus(0, android.os.Bundle().apply { putString("stream", "PACE_HEVC_CAPS $line\n") })
        }
    }

    private fun assertHeavyHevc(file: File) {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(file.absolutePath)
            val video = (0 until extractor.trackCount).map { extractor.getTrackFormat(it) }
                .first { it.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true }
            assertEquals("Real fixture must exercise HEVC decoding", "video/hevc", video.getString(MediaFormat.KEY_MIME))
            assertTrue("Fixture must be 4K", max(video.getInteger(MediaFormat.KEY_WIDTH), video.getInteger(MediaFormat.KEY_HEIGHT)) >= 3840)
            val fps = try { video.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble() }
                catch (_: ClassCastException) { video.getFloat(MediaFormat.KEY_FRAME_RATE).toDouble() }
            assertTrue("Fixture must carry nominal60fps metadata", fps >= 50)
        } finally { extractor.release() }
    }

    private fun inspectPreview(source: File, file: File, result: Map<*, *>) {
        val metadata = MediaMetadataRetriever()
        val originalMetadata = MediaMetadataRetriever()
        val extractor = MediaExtractor()
        try {
            metadata.setDataSource(file.absolutePath)
            originalMetadata.setDataSource(source.absolutePath)
            val duration = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toLong()
            val originalDuration = originalMetadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toLong()
            assertTrue("Original timeline must not be trimmed or stretched", abs(duration - originalDuration) <= 250)
            val width = (result["width"] as Number).toInt()
            val height = (result["height"] as Number).toInt()
            assertTrue("Preview exceeds 720p box", max(width, height) <= 1280 && min(width, height) <= 720)
            if (originalMetadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes") {
                assertEquals("Source audio was dropped", "yes", metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO))
            }
            extractor.setDataSource(file.absolutePath)
            var videoTrack = -1
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("video/")) {
                    assertEquals("video/avc", mime); videoTrack = index
                } else if (mime.startsWith("audio/")) assertEquals("audio/mp4a-latm", mime)
            }
            assertTrue(videoTrack >= 0)
            extractor.selectTrack(videoTrack)
            var first = -1L; var last = -1L; var count = 0
            while (extractor.sampleTime >= 0) {
                val at = extractor.sampleTime
                if (first < 0) first = at
                last = max(last, at); count++
                if (!extractor.advance()) break
            }
            assertTrue("Actual sample timestamps exceed30fps", (count - 1) * 1e6 / (last - first) <= 30.5)
            val times = listOf(0L, min(1_000_000L, duration * 500), min(2_000_000L, duration * 800))
            for (at in times) {
                val expected = originalMetadata.getScaledFrameAtTime(at, MediaMetadataRetriever.OPTION_CLOSEST, 64, 64)
                val actual = metadata.getScaledFrameAtTime(at, MediaMetadataRetriever.OPTION_CLOSEST, 64, 64)
                assertNotNull("Cannot decode source at$at", expected)
                assertNotNull("Cannot decode preview at$at", actual)
                // Compare decoded content at the same source time; this is not a playback smoothness measurement.
                assertTrue("Preview frame does not match original timeline at$at", imageDistance(expected!!, actual!!) < 65)
                expected.recycle(); actual.recycle()
            }
        } finally { extractor.release(); metadata.release(); originalMetadata.release() }
    }

    private fun imageDistance(first: Bitmap, second: Bitmap): Double {
        val a = Bitmap.createScaledBitmap(first, 32, 32, true)
        val b = Bitmap.createScaledBitmap(second, 32, 32, true)
        var difference = 0L
        for (y in 0 until 32) for (x in 0 until 32) {
            val p = a.getPixel(x, y); val q = b.getPixel(x, y)
            difference += abs(android.graphics.Color.red(p) - android.graphics.Color.red(q))
            difference += abs(android.graphics.Color.green(p) - android.graphics.Color.green(q))
            difference += abs(android.graphics.Color.blue(p) - android.graphics.Color.blue(q))
        }
        if (a !== first) a.recycle()
        if (b !== second) b.recycle()
        return difference.toDouble() / (32 * 32 * 3)
    }

    private fun digest(file: File): String {
        val sha = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) { val count = input.read(buffer); if (count < 0) break; sha.update(buffer, 0, count) }
        }
        return sha.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
    }
}
