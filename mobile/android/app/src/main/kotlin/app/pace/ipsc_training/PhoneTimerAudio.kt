package app.pace.ipsc_training

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.*
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.*

/** Live audio is reduced to features in memory; no recording is stored. */
class PhoneTimerAudio(private val activity: Activity, messenger: BinaryMessenger) {
    private val handler = Handler(Looper.getMainLooper())
    private val manager = activity.getSystemService(AudioManager::class.java)
    private val events = EventChannel(messenger, "pace/microphone")
    private var sink: EventChannel.EventSink? = null
    private var microphone: Capture? = null
    private var beep: AudioTrack? = null
    var foreground = true

    private class Capture(val recorder: AudioRecord) {
        @Volatile var running = true
    }

    init {
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
                stopMicrophone("replaced")
                sink = eventSink
            }
            override fun onCancel(arguments: Any?) {
                stopMicrophone("cancelled")
                sink = null
            }
        })
    }

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (call.method !in listOf("beep", "stopBeep", "audioStatus", "micStart", "micStop")) return false
        try {
            when (call.method) {
                "beep" -> result.success(playBeep(call))
                "stopBeep" -> { stopBeep(); result.success(null) }
                "audioStatus" -> result.success(audioStatus())
                "micStart" -> result.success(startMicrophone())
                "micStop" -> { stopMicrophone("requested"); result.success(null) }
            }
        } catch (error: Exception) {
            if (call.method == "beep") stopBeep()
            result.error(call.method, error.message ?: "Audio unavailable", null)
        }
        return true
    }

    private fun audioStatus() = mapOf(
        "mediaVolume" to manager.getStreamVolume(AudioManager.STREAM_MUSIC),
        "mediaMax" to manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
    )

    private fun playBeep(call: MethodCall): Map<String, Any> {
        check(foreground || (microphone != null && PhoneTimerService.active)) { "Start the timer while the app is visible" }
        val duration = (call.argument<Number>("durationMs")?.toInt() ?: 600).coerceIn(150, 1500)
        val gain = call.argument<Number>("gain")?.toDouble() ?: 1.0
        require(gain.isFinite()) { "Invalid beep gain" }
        val rate = 44100
        val pcm = ShortArray(rate * duration / 1000) { i ->
            val envelope = min(1.0, min(i, rate * duration / 1000 - 1 - i) / (rate * .005))
            (sin(2 * PI * 2300 * i / rate) * envelope * gain.coerceIn(.1, 1.0) * 32767).roundToInt().toShort()
        }
        stopBeep()
        val track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(rate)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setTransferMode(AudioTrack.MODE_STATIC).setBufferSizeInBytes(pcm.size * 2).build()
        beep = track
        // Static tracks become initialized only after their first PCM write.
        check(track.state != AudioTrack.STATE_UNINITIALIZED) { "Signal output unavailable" }
        check(track.write(pcm, 0, pcm.size) == pcm.size) { "Signal buffer incomplete" }
        check(track.state == AudioTrack.STATE_INITIALIZED) { "Signal buffer unavailable" }
        track.play()
        val at = System.nanoTime() / 1e9
        handler.postDelayed({ if (beep === track) stopBeep() }, duration.toLong() + 150)
        return audioStatus() + mapOf("at" to at, "durationMs" to duration)
    }

    private fun stopBeep() {
        val track = beep ?: return
        beep = null
        try { track.stop() } catch (_: IllegalStateException) { }
        track.release()
    }

    private fun startMicrophone(): Map<String, Any> {
        check(foreground) { "Microphone requires foreground app" }
        check(sink != null) { "Subscribe to pace/microphone before micStart" }
        check(activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            "Microphone permission is required"
        }
        check(microphone == null) { "Microphone is already running" }
        val preferredSource = if (Build.VERSION.SDK_INT >= 24 &&
            manager.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED) == "true")
            MediaRecorder.AudioSource.UNPROCESSED else MediaRecorder.AudioSource.VOICE_RECOGNITION
        var recorder: AudioRecord? = null
        var source = preferredSource
        sources@ for (candidateSource in listOf(preferredSource, MediaRecorder.AudioSource.VOICE_RECOGNITION).distinct()) {
            for (rate in listOf(48000, 44100)) {
                val minimum = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
                if (minimum <= 0) continue
                val candidate = try {
                    AudioRecord(candidateSource, rate, AudioFormat.CHANNEL_IN_MONO,
                        AudioFormat.ENCODING_PCM_16BIT, max(minimum, rate / 5 * 2))
                } catch (_: IllegalArgumentException) { continue }
                if (candidate.state == AudioRecord.STATE_INITIALIZED) {
                    recorder = candidate
                    source = candidateSource
                    break@sources
                }
                candidate.release()
            }
        }
        val record = checkNotNull(recorder) { "Microphone PCM input unavailable" }
        try {
            PhoneTimerService.onStopped = { stopMicrophone("service") }
            PhoneTimerService.start(activity)
            record.startRecording()
            check(record.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "Microphone failed to start" }
        } catch (error: Exception) {
            PhoneTimerService.onStopped = null
            PhoneTimerService.stop(activity)
            record.release(); throw error
        }
        val ready = System.nanoTime() / 1e9
        val capture = Capture(record)
        microphone = capture
        val target = sink!!
        Thread({ captureFrames(capture, target, ready) }, "pace-microphone").start()
        return mapOf("at" to ready, "sampleRate" to record.sampleRate,
            "audioSource" to if (source == MediaRecorder.AudioSource.UNPROCESSED) "unprocessed" else "voiceRecognition",
            "timestampSource" to "audioTimestampOrStartAnchor")
    }

    private fun captureFrames(capture: Capture, target: EventChannel.EventSink, ready: Double) {
        val record = capture.recorder
        val rate = record.sampleRate
        val samples = ShortArray(rate / 100)
        val timestamp = AudioTimestamp()
        var framePosition = 0L
        var anchor = ready
        var failure: Exception? = null
        var limit = false
        try {
            while (capture.running) {
                check(activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                    "Microphone permission revoked"
                }
                if (Build.VERSION.SDK_INT >= 29 && framePosition % (rate / 2) == 0L) {
                    check(record.activeRecordingConfiguration?.isClientSilenced != true) {
                        "Microphone input was silenced by Android"
                    }
                }
                if (System.nanoTime() / 1e9 - ready >= 600) { limit = true; break }
                var count = 0
                while (count < samples.size && capture.running) {
                    val read = record.read(samples, count, samples.size - count, AudioRecord.READ_BLOCKING)
                    check(read > 0) { "Microphone read failed: $read" }
                    count += read
                }
                if (!capture.running) break
                if (Build.VERSION.SDK_INT >= 24 && record.getTimestamp(timestamp, AudioTimestamp.TIMEBASE_MONOTONIC) == AudioRecord.SUCCESS) {
                    anchor = timestamp.nanoTime / 1e9 - timestamp.framePosition.toDouble() / rate
                }
                // shortcut: fallback anchor includes unknown device input latency; calibrate on the actual route.
                val at = anchor + framePosition.toDouble() / rate
                framePosition += count
                val event = features(samples, rate, at)
                handler.post { if (microphone === capture && capture.running && sink === target) target.success(event) }
            }
        } catch (error: Exception) { if (capture.running) failure = error }
        finally {
            capture.running = false
            try { record.stop() } catch (_: IllegalStateException) { }
            record.release()
            handler.post {
                if (microphone === capture) {
                    microphone = null
                    PhoneTimerService.onStopped = null
                    PhoneTimerService.stop(activity)
                    if (sink === target) {
                        failure?.let { target.error("microphone", it.message, null) }
                        target.success(mapOf("event" to "stopped", "reason" to if (limit) "limit" else "error"))
                    }
                }
            }
        }
    }

    private fun features(samples: ShortArray, rate: Int, at: Double): Map<String, Any> {
        var energy = 0.0
        var peak = 0.0
        var previous = 0.0
        var before = 0.0
        val coefficient = 2 * cos(2 * PI * 2300 / rate)
        var clipped = false
        for (pcm in samples) {
            val sample = pcm / 32768.0
            energy += sample * sample
            peak = max(peak, abs(sample))
            clipped = clipped || abs(pcm.toInt()) >= 32760
            val value = sample + coefficient * previous - before
            before = previous
            previous = value
        }
        val power = previous * previous + before * before - coefficient * previous * before
        return mapOf("at" to at, "rms" to sqrt(energy / samples.size), "peak" to peak,
            "toneRatio" to if (energy > 0) (2 * power / (samples.size * energy)).coerceIn(0.0, 1.0) else 0.0,
            "clipped" to clipped)
    }

    private fun stopMicrophone(reason: String) {
        PhoneTimerService.onStopped = null
        PhoneTimerService.stop(activity)
        val capture = microphone ?: return
        microphone = null
        capture.running = false
        // stop unblocks READ_BLOCKING; the capture thread alone releases the recorder.
        try { capture.recorder.stop() } catch (_: IllegalStateException) { }
        sink?.success(mapOf("event" to "stopped", "reason" to reason))
    }

    fun background() {
        foreground = false
        if (microphone == null) stopBeep()
    }

    fun dispose() {
        foreground = false
        stopMicrophone("disposed")
        stopBeep()
        sink = null
        events.setStreamHandler(null)
        handler.removeCallbacksAndMessages(null)
    }
}
