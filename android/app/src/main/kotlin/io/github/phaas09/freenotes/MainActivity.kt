package io.github.phaas09.freenotes

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Screen recording for the app ("freenotes/recorder"): asks for the microphone if wanted, then for
 *  the screen (Android asks every time), and hands over to [RecorderService]. */
class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var path = ""
    private var audio = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "freenotes/recorder").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    if (pending != null || ScreenRecorder.running) {
                        result.error("busy", "Es läuft schon eine Aufnahme.", null)
                        return@setMethodCallHandler
                    }
                    pending = result
                    path = call.argument<String>("path")!!
                    audio = call.argument<Boolean>("audio") ?: false
                    if (audio && checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC)
                    } else {
                        askScreen()
                    }
                }
                "stop" -> ScreenRecorder.stop(this, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun askScreen() {
        val mpm = getSystemService(MediaProjectionManager::class.java)
        @Suppress("DEPRECATION")
        startActivityForResult(mpm.createScreenCaptureIntent(), SCREEN)
    }

    private fun fail(message: String) {
        pending?.error("start", message, null)
        pending = null
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != MIC) return
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) askScreen()
        else fail("Kein Zugriff auf das Mikrofon. Erlaube es in den App-Einstellungen oder nimm ohne Ton auf.")
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != SCREEN) return
        if (resultCode != Activity.RESULT_OK || data == null) return fail("Aufnahme abgebrochen.")
        val result = pending ?: return
        pending = null
        ScreenRecorder.onStarted = { error -> if (error == null) result.success(null) else result.error("start", error, null) }
        val service = Intent(this, RecorderService::class.java)
            .putExtra("code", resultCode).putExtra("data", data).putExtra("path", path).putExtra("audio", audio)
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(service) else startService(service)
    }

    companion object {
        const val MIC = 41
        const val SCREEN = 42
    }
}
