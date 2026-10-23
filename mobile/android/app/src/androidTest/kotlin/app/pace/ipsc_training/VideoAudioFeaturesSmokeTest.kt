package app.pace.ipsc_training

import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.MessageDigest

/** Exercises the production AAC decoder and exports features for the real Dart detector. */
@RunWith(AndroidJUnit4::class)
class VideoAudioFeaturesSmokeTest {
    @Test fun rawFixtureAudioFeaturesPreserveQuiet2300HzTone() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val fixtures = File(context.getExternalFilesDir(null), "preview_smoke")
        val args = InstrumentationRegistry.getArguments()
        val sources = listOf(
            File(args.getString("previewPrimary") ?: File(fixtures, "a.mp4").absolutePath),
            File(args.getString("previewComparison") ?: File(fixtures, "b.mp4").absolutePath),
        )
        val toneIssues = mutableListOf<String>()
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var activity: MainActivity
            scenario.onActivity { activity = it }
            val decode = MainActivity::class.java.getDeclaredMethod("audioFrames", String::class.java)
                .apply { isAccessible = true }
            sources.forEachIndexed { index, source ->
                assertTrue("Prepare raw fixture ${source.absolutePath}", source.isFile)
                val before = digest(source)
                // Reflection remains test-only; decoding runs on the instrumentation thread.
                @Suppress("UNCHECKED_CAST")
                val frames = decode.invoke(activity, source.absolutePath) as List<List<Double>>
                assertTrue("AAC decoder returned no frames", frames.isNotEmpty())
                var previous = -1.0
                for (frame in frames) {
                    assertTrue("Unexpected feature shape", frame.size == 3 || frame.size == 4)
                    assertTrue("Non-finite decoded feature", frame.all { it.isFinite() })
                    assertTrue("Audio timestamps must increase", frame[0] > previous)
                    assertTrue("Invalid RMS", frame[1] in 0.0..1.0)
                    assertTrue("Invalid tone energy fraction", frame[2] in 0.0..1.0)
                    if (frame.size == 4) assertTrue("Invalid frequency", frame[3] in 0.0..5000.0)
                    previous = frame[0]
                }
                val approximateOnset = if (index == 0) .90 else 1.02
                val toneFrames = frames.filter { frame ->
                    frame[0] in (approximateOnset - .08)..(approximateOnset + .80) &&
                        frame[2] >= .15 && (frame.size == 3 || frame[3] in 2250.0..2350.0)
                }
                val quietToneFrames = toneFrames.count { it[1] > 0 && it[1] <= .025 }
                val name = if (index == 0) "a" else "b"
                val output = File(context.filesDir, "audio-smoke-$name.json")
                val temporary = File(context.filesDir, "audio-smoke-$name.tmp")
                temporary.writeText(JSONArray(frames.map { JSONArray(it) }).toString())
                check(temporary.renameTo(output)) { "Could not publish audio feature evidence" }
                assertEquals("Audio analysis modified the original", before, digest(source))
                instrumentation.sendStatus(0, android.os.Bundle().apply {
                    putString("stream", "PACE_AUDIO_SMOKE fixture=$name frames=${frames.size} toneFrames=${toneFrames.size} quietToneFrames=$quietToneFrames path=${output.absolutePath}\n")
                })
                if (toneFrames.size < 8) toneIssues.add("$name sustained2300Hz frames=${toneFrames.size}<8")
                if (quietToneFrames < 8) toneIssues.add("$name quiet2300Hz frames=$quietToneFrames<8")
            }
        }
        assertTrue(toneIssues.joinToString("; "), toneIssues.isEmpty())
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
