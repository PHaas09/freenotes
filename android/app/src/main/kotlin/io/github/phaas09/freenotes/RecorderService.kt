package io.github.phaas09.freenotes

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.MethodChannel

/** Android only lets an app record the screen from a foreground service with a visible notification. */
class RecorderService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) return START_NOT_STICKY
        val audio = intent.getBooleanExtra("audio", false)
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(NotificationChannel("rec", "Bildschirmaufnahme", NotificationManager.IMPORTANCE_LOW))
            Notification.Builder(this, "rec")
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        val note = builder.setContentTitle("FreeNotes nimmt den Bildschirm auf")
            .setContentText("Beenden über den roten Knopf in FreeNotes")
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            if (audio && Build.VERSION.SDK_INT >= 30) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            startForeground(1, note, type)
        } else {
            startForeground(1, note)
        }
        ScreenRecorder.start(this, intent)
        return START_NOT_STICKY
    }
}

/** The running recording: screen (and microphone) into an MP4 file with the system's video encoder. */
object ScreenRecorder {
    var onStarted: ((String?) -> Unit)? = null
    private var recorder: MediaRecorder? = null
    private var display: VirtualDisplay? = null
    private var projection: MediaProjection? = null
    private var started = 0L
    private var endedMs: Long? = null // set if Android ended the recording itself (e.g. "stop sharing")
    val running get() = recorder != null

    fun start(service: Service, intent: Intent) {
        val done = onStarted
        onStarted = null
        try {
            val data: Intent? = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra("data", Intent::class.java)
            else @Suppress("DEPRECATION") intent.getParcelableExtra("data")
            val p = service.getSystemService(MediaProjectionManager::class.java).getMediaProjection(intent.getIntExtra("code", 0), data!!)
                ?: throw IllegalStateException("Android hat die Bildschirmaufnahme nicht erlaubt.")
            val audio = intent.getBooleanExtra("audio", false)
            // the screen, at most 1920 pixels on the long side; video encoders want even sizes
            val m = service.resources.displayMetrics
            val k = minOf(1f, 1920f / maxOf(m.widthPixels, m.heightPixels))
            val w = (m.widthPixels * k).toInt() and 1.inv()
            val h = (m.heightPixels * k).toInt() and 1.inv()
            val r = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(service) else @Suppress("DEPRECATION") MediaRecorder()
            if (audio) r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setVideoSource(MediaRecorder.VideoSource.SURFACE)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setOutputFile(intent.getStringExtra("path"))
            r.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
            r.setVideoSize(w, h)
            r.setVideoFrameRate(30)
            r.setVideoEncodingBitRate(8_000_000)
            if (audio) {
                r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                r.setAudioSamplingRate(44100)
                r.setAudioEncodingBitRate(128_000)
            }
            r.prepare()
            p.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    finish(service) // stopped from outside the app: keep what was recorded
                }
            }, Handler(Looper.getMainLooper()))
            display = p.createVirtualDisplay("FreeNotes", w, h, m.densityDpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, r.surface, null, null)
            r.start()
            recorder = r
            projection = p
            started = SystemClock.elapsedRealtime()
            endedMs = null
            done?.invoke(null)
        } catch (e: Exception) {
            release()
            service.stopSelf()
            done?.invoke(e.message ?: e.toString())
        }
    }

    /** Ends the recording and the service; returns an error text if nothing usable was recorded. */
    private fun finish(ctx: Context): String? {
        val r = recorder ?: return null
        endedMs = SystemClock.elapsedRealtime() - started
        val error = try {
            r.stop()
            null
        } catch (e: RuntimeException) {
            "Die Aufnahme war zu kurz."
        }
        release()
        ctx.stopService(Intent(ctx, RecorderService::class.java))
        return error
    }

    fun stop(ctx: Context, result: MethodChannel.Result) {
        val error = if (recorder != null) finish(ctx) else null
        val ms = endedMs
        endedMs = null
        when {
            error != null -> result.error("stop", error, null)
            ms == null -> result.error("stop", "Es läuft keine Aufnahme.", null)
            else -> result.success(ms.toInt())
        }
    }

    private fun release() {
        recorder?.release()
        recorder = null
        display?.release()
        display = null
        projection?.stop()
        projection = null
    }
}
