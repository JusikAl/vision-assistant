package com.example.camera

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

/** Profile-only synthetic fixtures. Never shipped in the release APK. */
class WhisperValidation(private val context: Context, messenger: BinaryMessenger) : AutoCloseable {
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "navigation/whisper_validation")
    private var ready = false
    private var pending: MethodChannel.Result? = null
    private val file = File(context.cacheDir, "whisper-fixture.wav")
    private val tts = TextToSpeech(context) { status -> ready = status == TextToSpeech.SUCCESS }
    init {
        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String?) {}
            override fun onError(id: String?) { main.post { pending?.error("tts", "Fixture synthesis failed", null); pending = null } }
            override fun onDone(id: String?) {
                val bytes = runCatching { file.readBytes() }.getOrNull()
                file.delete()
                main.post { if (bytes == null) pending?.error("tts", "No fixture", null) else pending?.success(bytes); pending = null }
            }
        })
        channel.setMethodCallHandler { call, result ->
            if (call.method != "fixture") { result.notImplemented(); return@setMethodCallHandler }
            if (!ready || pending != null) { result.error("tts", "Fixture engine not ready/busy", null); return@setMethodCallHandler }
            val voice = tts.voices?.firstOrNull { it.locale.language == "ru" && !it.isNetworkConnectionRequired && !it.features.contains("notInstalled") }
            if (voice == null) { result.error("tts", "Offline Russian voice required", null); return@setMethodCallHandler }
            tts.language = Locale.forLanguageTag("ru-RU")
            tts.voice = voice
            tts.setSpeechRate((call.argument<Double>("rate") ?: 1.0).toFloat())
            pending = result
            val code = tts.synthesizeToFile(call.argument<String>("text") ?: "", null, file, "fixture")
            if (code != TextToSpeech.SUCCESS) { pending = null; result.error("tts", "Cannot synthesize", null) }
        }
    }
    override fun close() { tts.stop(); tts.shutdown(); file.delete(); channel.setMethodCallHandler(null) }
}
