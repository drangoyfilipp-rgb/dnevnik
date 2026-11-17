package ru.drangoy.dnevnik

import android.os.Build
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FragmentActivity is required by local_auth (biometric prompt).
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dnevnik/system").setMethodCallHandler { call, result ->
            when (call.method) {
                // Material You: the wallpaper accent colour (Android 12+), used as the theme seed.
                "accentColor" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    result.success(resources.getColor(android.R.color.system_accent1_500, theme))
                } else {
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
