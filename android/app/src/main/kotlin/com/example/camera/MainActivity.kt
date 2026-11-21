package com.example.camera

import android.os.Debug
import android.os.Process
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var vosk: VoskBridge? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        vosk = VoskBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "navigation/performance")
            .setMethodCallHandler { call, result ->
                if (call.method != "snapshot") {
                    result.notImplemented()
                } else {
                    // On-demand diagnostics only: no polling on the camera thread.
                    val runtime = Debug.getRuntimeStats()
                    // Optional local-plugin counters; absent with upstream CameraX.
                    val packing = runCatching {
                        Class.forName("io.flutter.plugins.camerax.ImageProxyUtilsProxyApi")
                            .getMethod("packingStats").invoke(null)
                    }.getOrNull()
                    result.success(mapOf(
                        "camera_packing" to packing,
                        "cpu_ms" to Process.getElapsedCpuTime(),
                        "java_allocated_bytes" to (runtime["art.gc.bytes-allocated"]?.toLongOrNull() ?: 0L),
                        "java_gc_count" to (runtime["art.gc.gc-count"]?.toLongOrNull() ?: 0L),
                        "java_gc_ms" to (runtime["art.gc.gc-time"]?.toLongOrNull() ?: 0L),
                        "native_heap_bytes" to Debug.getNativeHeapAllocatedSize(),
                        "pss_kb" to Debug.getPss()
                    ))
                }
            }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        vosk?.onPermissionResult(requestCode, grantResults)
    }
    override fun onStop() {
        vosk?.cancel()
        super.onStop()
    }
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        vosk?.close()
        vosk = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
