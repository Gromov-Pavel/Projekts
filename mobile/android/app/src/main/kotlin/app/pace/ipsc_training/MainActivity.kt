package app.pace.ipsc_training

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.AudioFormat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteOrder
import kotlin.math.*

class MainActivity : FlutterActivity() {
    private lateinit var phoneAudio: PhoneTimerAudio
    private var activityStarted = false
    private lateinit var videoExporter: VideoAnalysisExporter
    private lateinit var videoPreview: VideoPreview
    private var watchPhoneBridge: WatchPhoneBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        watchPhoneBridge = WatchPhoneBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        phoneAudio = PhoneTimerAudio(this, flutterEngine.dartExecutor.binaryMessenger)
        videoExporter = VideoAnalysisExporter(this)
        videoPreview = VideoPreview(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pace/audio").setMethodCallHandler { call, result ->
            if (videoPreview.handle(call, result)) return@setMethodCallHandler
            if (videoExporter.handle(call, result)) return@setMethodCallHandler
            if (call.method == "timerServiceStart" || call.method == "timerServiceStop") {
                try {
                    val service = Intent(this, TimerConnectionService::class.java)
                    if (call.method == "timerServiceStart") {
                        check(activityStarted) { "Connect the timer while the app is visible" }
                        check(Build.VERSION.SDK_INT < 31 || checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED) {
                            "Bluetooth permission is required"
                        }
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(service) else startService(service)
                    } else stopService(service)
                    result.success(null)
                } catch (error: Exception) {
                    result.error("timerService", error.message ?: "Timer background connection unavailable", null)
                }
                return@setMethodCallHandler
            }
            if (phoneAudio.handle(call, result)) return@setMethodCallHandler
            if (call.method == "appVersion") {
                result.success(packageManager.getPackageInfo(packageName, 0).versionName); return@setMethodCallHandler
            }
            if (call.method == "androidSdk") { result.success(android.os.Build.VERSION.SDK_INT); return@setMethodCallHandler }
            if (call.method != "analyze") { result.notImplemented(); return@setMethodCallHandler }
            val path = call.argument<String>("path")
            if (path == null) { result.error("path", "Video path missing", null); return@setMethodCallHandler }
            Thread {
                try {
                    val frames = audioFrames(path)
                    runOnUiThread { result.success(frames) }
                } catch (error: Exception) {
                    runOnUiThread { result.error("audio", error.message ?: "Audio decoding failed", null) }
                }
            }.start()
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        watchPhoneBridge?.close()
        watchPhoneBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onStart() {
        super.onStart()
        activityStarted = true
        if (::phoneAudio.isInitialized) phoneAudio.foreground = true
    }

    override fun onStop() {
        activityStarted = false
        if (::phoneAudio.isInitialized) phoneAudio.background()
        super.onStop()
    }

    override fun onDestroy() {
        if (::videoPreview.isInitialized) videoPreview.dispose()
        if (::videoExporter.isInitialized) videoExporter.dispose()
        if (!isChangingConfigurations) stopService(Intent(this, TimerConnectionService::class.java))
        if (::phoneAudio.isInitialized) phoneAudio.dispose()
        super.onDestroy()
    }

    private fun audioFrames(path: String): List<List<Double>> {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(path)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: throw IllegalArgumentException("В видео нет звуковой дорожки")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            require(!format.containsKey(MediaFormat.KEY_DURATION) || format.getLong(MediaFormat.KEY_DURATION) <= 600_000_000L) {
                "Анализ ограничен видео до 10 минут"
            }
            val decoder = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec = decoder
            decoder.configure(format, null, null, 0)
            decoder.start()
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var encoding = AudioFormat.ENCODING_PCM_16BIT
            var size = (rate * .02).roundToInt()
            var frame = Array(channels) { DoubleArray(size) }
            var count = 0
            var frameTime = 0.0
            var inputDone = false
            var outputDone = false
            val info = MediaCodec.BufferInfo()
            val frames = mutableListOf<List<Double>>()
            val deadline = System.nanoTime() + 180_000_000_000L
            while (!outputDone) {
                check(System.nanoTime() < deadline) { "Истекло время анализа аудио" }
                if (!inputDone) {
                    val index = decoder.dequeueInputBuffer(10000)
                    if (index >= 0) {
                        val buffer = decoder.getInputBuffer(index)!!
                        val bytes = extractor.readSampleData(buffer, 0)
                        if (bytes < 0) {
                            decoder.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            require(extractor.sampleTime <= 600_000_000L) { "Анализ ограничен 10 минутами" }
                            decoder.queueInputBuffer(index, 0, bytes, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val index = decoder.dequeueOutputBuffer(info, 10000)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val output = decoder.outputFormat
                    rate = output.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = output.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    if (output.containsKey(MediaFormat.KEY_PCM_ENCODING)) encoding = output.getInteger(MediaFormat.KEY_PCM_ENCODING)
                    require(encoding == AudioFormat.ENCODING_PCM_16BIT || encoding == AudioFormat.ENCODING_PCM_FLOAT) { "Неподдерживаемый PCM формат" }
                    size = (rate * .02).roundToInt()
                    frame = Array(channels) { DoubleArray(size) }
                    count = 0
                } else if (index >= 0) {
                    val buffer = decoder.getOutputBuffer(index)!!
                    buffer.order(ByteOrder.LITTLE_ENDIAN)
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    val bytesPerSample = if (encoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2
                    var sampleIndex = 0
                    while (buffer.remaining() >= channels * bytesPerSample) {
                        if (count == 0) frameTime = info.presentationTimeUs / 1e6 + sampleIndex.toDouble() / rate
                        repeat(channels) { channel ->
                            frame[channel][count] = if (encoding == AudioFormat.ENCODING_PCM_FLOAT) buffer.float.toDouble() else buffer.short / 32768.0
                        }
                        count++
                        sampleIndex++
                        if (count == size) {
                            // Preserve opposite-phase stereo tones by choosing a whole channel per window.
                            val loudest = frame.maxBy { channel -> channel.sumOf { it * it } }
                            frames.add(feature(loudest, rate, frameTime))
                            count = 0
                            require(frames.size <= 30001) { "Анализ ограничен 10 минутами" }
                        }
                    }
                    outputDone = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    decoder.releaseOutputBuffer(index, false)
                }
            }
            return frames
        } finally {
            try { codec?.stop() } catch (_: Exception) { }
            codec?.release()
            extractor.release()
        }
    }

    private fun feature(samples: DoubleArray, rate: Int, time: Double): List<Double> {
        val energy = samples.sumOf { it * it }
        var peak = 0.0
        var frequencyHz = 0.0
        for (hz in 1250..min(5000, rate / 2 - 250) step 50) {
            val coefficient = 2 * cos(2 * PI * hz / rate)
            var previous = 0.0
            var before = 0.0
            for (sample in samples) {
                val value = sample + coefficient * previous - before
                before = previous
                previous = value
            }
            val power = previous * previous + before * before - coefficient * previous * before
            if (power > peak) { peak = power; frequencyHz = hz.toDouble() }
        }
        return listOf(time, sqrt(energy / samples.size), if (energy > 0) (2 * peak / (samples.size * energy)).coerceIn(0.0, 1.0) else 0.0, frequencyHz)
    }
}
