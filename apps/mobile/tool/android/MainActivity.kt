package org.fingerspeak.mobile

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.fingerspeak.mobile/research",
        ).setMethodCallHandler { call, result ->
            if (call.method != "log") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val line = call.arguments as? String
            if (
                line == null ||
                !line.startsWith("FINGERSPEAK_RESEARCH ") ||
                line.length > 3500
            ) {
                result.error("INVALID_RESEARCH_EVENT", "Invalid research log line", null)
                return@setMethodCallHandler
            }
            Log.i("FingerSpeakResearch", line)
            result.success(null)
        }
    }
}
