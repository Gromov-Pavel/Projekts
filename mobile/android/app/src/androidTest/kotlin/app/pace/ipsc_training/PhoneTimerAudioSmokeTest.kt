package app.pace.ipsc_training

import android.media.AudioTrack
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PhoneTimerAudioSmokeTest {
    private class Reply : MethodChannel.Result {
        var value: Any? = null
        var failure: String? = null
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) { failure = "$code: $message" }
        override fun notImplemented() { failure = "Not implemented" }
    }

    @Test fun staticBeepLoadsPlaysStopsAndRestarts() {
        val audioField = MainActivity::class.java.getDeclaredField("phoneAudio").apply { isAccessible = true }
        val trackField = PhoneTimerAudio::class.java.getDeclaredField("beep").apply { isAccessible = true }
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            repeat(2) {
                lateinit var audio: PhoneTimerAudio
                lateinit var track: AudioTrack
                scenario.onActivity { activity ->
                    audio = audioField.get(activity) as PhoneTimerAudio
                    val reply = Reply()
                    assertTrue(audio.handle(MethodCall("beep", mapOf("durationMs" to 400, "gain" to .1)), reply))
                    assertNull("Production beep must load PCM before checking static-track state", reply.failure)
                    val output = reply.value as Map<*, *>
                    assertEquals(400, output["durationMs"])
                    assertTrue((output["at"] as Double).isFinite())
                    track = trackField.get(audio) as AudioTrack
                    assertEquals(AudioTrack.STATE_INITIALIZED, track.state)
                    assertEquals(AudioTrack.PLAYSTATE_PLAYING, track.playState)
                }
                SystemClock.sleep(150)
                scenario.onActivity {
                    assertTrue("PCM playback must advance", track.playbackHeadPosition > 0)
                    val reply = Reply()
                    audio.handle(MethodCall("stopBeep", null), reply)
                    assertNull(reply.failure)
                    assertNull("Stopped track must be released", trackField.get(audio))
                }
            }
            scenario.onActivity { activity ->
                val audio = audioField.get(activity) as PhoneTimerAudio
                audio.foreground = false
                val reply = Reply()
                audio.handle(MethodCall("beep", mapOf("durationMs" to 400, "gain" to .1)), reply)
                assertTrue(reply.failure?.contains("background") == true)
                assertNull(trackField.get(audio))
                audio.foreground = true
            }
        }
    }
}
