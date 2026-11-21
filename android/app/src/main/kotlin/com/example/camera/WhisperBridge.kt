package com.example.camera

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.Process
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

@androidx.annotation.Keep
class WhisperBridge(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "navigation/whisper")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread({ Process.setThreadPriority(Process.THREAD_PRIORITY_LOWEST); task.run() }, "whisper-cpu")
    }
    private val busy = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    // Accessed only on worker. Cancellation uses a separate global atomic epoch.
    private var handle = 0L
    @Volatile private var libraryLoaded = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (closed.get()) { result.error("disposed", "Whisper disposed", null); return@setMethodCallHandler }
            when (call.method) {
                "cancel" -> { cancel(); result.success(null) }
                "dispose" -> {
                    cancel()
                    worker.execute { if (handle != 0L) nativeFree(handle); handle = 0 }
                    result.success(null)
                }
                "initialize", "transcribe" -> {
                    if (!busy.compareAndSet(false, true)) {
                        result.error("busy", "Whisper operation already active", null)
                        return@setMethodCallHandler
                    }
                    val pcm = call.argument<ByteArray>("pcm")
                    val diagnostic = call.argument<Boolean>("diagnostic") == true
                    val threads = if (diagnostic) (call.argument<Int>("threads") ?: 2) else 1
                    val greedy = diagnostic && call.argument<Boolean>("greedy") == true
                    val fullContext = diagnostic && call.argument<Boolean>("full_context") == true
                    val token = if (libraryLoaded) nativeEpoch() else 0L
                    worker.execute {
                        try {
                            check(!closed.get()) { "Whisper disposed" }
                            if (call.method == "initialize") {
                                val started = System.nanoTime()
                                if (!libraryLoaded) {
                                    System.loadLibrary("navigation_whisper")
                                    libraryLoaded = true
                                }
                                if (handle == 0L) {
                                    val model = installModel()
                                    handle = nativeLoad(model.absolutePath)
                                    check(handle != 0L) { "Cannot load Whisper Tiny Multilingual" }
                                }
                                val payload = mapOf("load_ms" to (System.nanoTime()-started)/1e6)
                                main.post { result.success(payload) }
                            } else {
                                check(handle != 0L) { "Initialize Whisper first" }
                                require(pcm != null && pcm.size in 6400..160000 && pcm.size % 2 == 0) { "Expected 0.2–5 seconds PCM16 mono 16kHz" }
                                val started = System.nanoTime()
                                require(threads in 1..4)
                                val wav = if (diagnostic) saveWav(pcm) else null
                                val output = nativeTranscribe(handle, pcm, token, threads, greedy, fullContext, diagnostic)
                                check(output != null && nativeEpoch() == token && !closed.get()) { "Whisper cancelled" }
                                val payload = mapOf("text" to output[0], "avg_logprob" to output[1].toDouble(),
                                    "no_speech_prob" to output[2].toDouble(), "inference_ms" to output[4].toDouble(),
                                    "preparation_ms" to output[3].toDouble(),
                                    "native_wall_ms" to (System.nanoTime()-started)/1e6,
                                    "samples" to pcm.size / 2, "wav_path" to wav?.absolutePath,
                                    "model" to "ggml-tiny.bin", "model_sha256" to MODEL_SHA256,
                                    "language" to "ru", "translate" to false, "no_context" to true,
                                    "threads" to threads, "greedy" to greedy, "full_context" to fullContext)
                                main.post { result.success(payload) }
                            }
                        } catch (error: Throwable) {
                            main.post { result.error("whisper", error.message ?: "Native Whisper failed", null) }
                        } finally { busy.set(false) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun saveWav(pcm: ByteArray): File {
        val directory = File(context.getExternalFilesDir(null), "whisper-diagnostics").apply { mkdirs() }
        val target = File(directory, "recording-${System.currentTimeMillis()}.wav")
        val header = java.nio.ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray()).putInt(36 + pcm.size).put("WAVEfmt ".toByteArray())
        header.putInt(16).putShort(1.toShort()).putShort(1.toShort()).putInt(16000).putInt(32000)
        header.putShort(2.toShort()).putShort(16.toShort()).put("data".toByteArray()).putInt(pcm.size)
        target.outputStream().use { it.write(header.array()); it.write(pcm) }
        return target
    }

    private fun installModel(): File {
        val target = File(context.filesDir, "ggml-tiny.bin")
        // An interrupted first extraction is never used as a model.
        if (target.isFile && target.length() == MODEL_BYTES && sha256(target) == MODEL_SHA256) return target
        val temporary = File(context.filesDir, "ggml-tiny.bin.partial")
        try {
            context.assets.open("flutter_assets/assets/models/ggml-tiny.bin").use { input ->
                temporary.outputStream().use { input.copyTo(it) }
            }
            check(temporary.length() == MODEL_BYTES && sha256(temporary) == MODEL_SHA256) { "Whisper model checksum mismatch" }
            check(temporary.renameTo(target)) { "Cannot install Whisper model" }
            return target
        } finally { temporary.delete() }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
    }

    fun cancel() { if (libraryLoaded) nativeCancel() }
    fun close() {
        if (!closed.compareAndSet(false, true)) return
        cancel()
        worker.execute { if (handle != 0L) nativeFree(handle); handle = 0 }
        worker.shutdown()
        channel.setMethodCallHandler(null)
    }
    private external fun nativeEpoch(): Long
    private external fun nativeCancel()
    private external fun nativeLoad(path: String): Long
    private external fun nativeFree(handle: Long)
    private external fun nativeTranscribe(handle: Long, pcm: ByteArray, epoch: Long, threads: Int, greedy: Boolean, fullContext: Boolean, diagnostic: Boolean): Array<String>?

    companion object {
        const val MODEL_BYTES = 77691713L
        const val MODEL_SHA256 = "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"
    }
}
