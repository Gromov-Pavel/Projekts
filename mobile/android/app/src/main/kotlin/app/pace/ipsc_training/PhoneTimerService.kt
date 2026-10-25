package app.pace.ipsc_training

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/** A user-started microphone session may continue while the screen is off. */
class PhoneTimerService : Service() {
    companion object {
        @Volatile var active = false
            private set
        var onStopped: (() -> Unit)? = null
        fun start(context: Context) {
            val intent = Intent(context, PhoneTimerService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        }
        fun stop(context: Context) { context.stopService(Intent(context, PhoneTimerService::class.java)) }
    }
    private var wakeLock: PowerManager.WakeLock? = null
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val channel = "phone_timer"
        if (Build.VERSION.SDK_INT >= 26) getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(channel, "Таймер телефона", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channel) else Notification.Builder(this)
        val notification = builder.setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("IPSC тренировОчка · таймер работает")
            .setContentText("Микрофон регистрирует выстрелы. Нажмите, чтобы открыть таймер.")
            .setContentIntent(open).setOngoing(true).setCategory(Notification.CATEGORY_SERVICE).build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(2301, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        else startForeground(2301, notification)
        active = true
        if (wakeLock == null) wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ipsc:phone-timer")
            .apply { setReferenceCounted(false); acquire(610_000) }
        return START_NOT_STICKY
    }
    override fun onTaskRemoved(rootIntent: Intent?) { stopSelf(); super.onTaskRemoved(rootIntent) }
    override fun onDestroy() {
        active = false
        val callback = onStopped; onStopped = null
        callback?.invoke()
        wakeLock?.let { if (it.isHeld) it.release() }; wakeLock = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
