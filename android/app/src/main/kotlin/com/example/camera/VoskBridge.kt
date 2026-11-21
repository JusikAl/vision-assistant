package com.example.camera

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import java.io.File
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/** Single owner of model, recognizer and microphone. All Vosk calls run on worker. */
class VoskBridge(private val activity: Activity, messenger: BinaryMessenger) : AutoCloseable {
    private val channel = MethodChannel(messenger, "navigation/vosk")
    private val events = EventChannel(messenger, "navigation/vosk/events")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread({ Process.setThreadPriority(Process.THREAD_PRIORITY_LOWEST); task.run() }, "vosk-audio")
    }
    private val epoch = AtomicLong(0)
    private val audioGate = Any()
    @Volatile private var microphoneOwned = false
    @Volatile private var stopped = false
    @Volatile private var closed = false
    private var sink: EventChannel.EventSink? = null
    private var model: Model? = null
    private var cpuPolicy: String? = null
    private var vocabulary: Map<String, Int> = emptyMap()
    private var active = false // main thread admission, includes queued start
    private var permission: (() -> Unit)? = null
    private var permissionResult: MethodChannel.Result? = null

    init {
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) { sink = eventSink }
            override fun onCancel(arguments: Any?) { sink = null; cancel() }
        })
        channel.setMethodCallHandler { call, result ->
            if (closed) { result.error("disposed", "Vosk disposed", null); return@setMethodCallHandler }
            when (call.method) {
                "logAction" -> {
                    val payload = JSONObject(call.arguments as Map<*, *>).toString()
                    worker.execute { appendEvidence(payload); main.post { result.success(null) } }
                }
                "saveReport" -> {
                    val json = call.argument<String>("json") ?: "[]"
                    val name = call.argument<String>("name") ?: "vosk-acceptance.json"
                    if (!name.matches(Regex("vosk[-a-z0-9]*\\.json"))) {
                        result.error("report", "Invalid report name", null); return@setMethodCallHandler
                    }
                    worker.execute {
                        try {
                            val target = File(activity.getExternalFilesDir(null), name)
                            target.writeText(json)
                            main.post { result.success(target.absolutePath) }
                        } catch (e: Throwable) { main.post { result.error("report", e.message, null) } }
                    }
                }
                "initialize" -> worker.execute {
                    try { val info = initialize(); main.post { result.success(info) } }
                    catch (e: Throwable) { main.post { result.error("model", e.message, null) } }
                }
                "replay" -> {
                    val pcm = call.argument<ByteArray>("pcm")
                    val endSeconds = call.argument<Number>("endpoint_end_s")?.toFloat()
                    val grammarId = call.argument<String>("grammar_id") ?: GRAMMAR_ID
                    if (pcm == null || pcm.isEmpty() || pcm.size > MAX_BYTES || pcm.size % 2 != 0 ||
                        (endSeconds != null && (!endSeconds.isFinite() || endSeconds !in 0.3f..2f)) ||
                        grammarId !in listOf(GRAMMAR_ID, "v1-commands")) {
                        result.error("replay", "Expected <=6s PCM16/16000/mono and supported endpoint/grammar", null)
                        return@setMethodCallHandler
                    }
                    worker.execute {
                        try { val report = replay(pcm, endSeconds, grammarId); main.post { result.success(report) } }
                        catch (e: Throwable) { main.post { result.error("replay", e.message, null) } }
                    }
                }
                "start" -> {
                    if (active) { result.error("busy", "Microphone session already active", null); return@setMethodCallHandler }
                    val session = call.argument<Int>("session") ?: 0
                    val capture = call.argument<Boolean>("diagnostic_capture") == true
                    active = true
                    stopped = false
                    val token = epoch.incrementAndGet()
                    val begin = {
                        worker.execute { recognize(session, token, result, capture) }
                        Unit
                    }
                    if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) begin()
                    else {
                        permission = begin
                        permissionResult = result
                        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST)
                    }
                }
                "stop" -> { stopped = true; worker.execute { main.post { result.success(null) } } }
                "cancel" -> {
                    val needsRelease = cancel()
                    if (needsRelease) worker.execute { main.post { result.success(null) } }
                    else result.success(null)
                }
                "dispose" -> {
                    cancel()
                    worker.execute { model?.close(); model = null; main.post { result.success(null) } }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun onPermissionResult(requestCode: Int, grants: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val begin = permission
        val result = permissionResult
        permission = null; permissionResult = null
        if (begin != null && !closed && grants.firstOrNull() == PackageManager.PERMISSION_GRANTED) begin()
        else { active = false; result?.error("permission", "Нет разрешения на микрофон", null) }
        return true
    }

    private fun emit(token: Long, payload: Map<String, Any?>) {
        main.post { if (!closed && epoch.get() == token) sink?.success(payload) }
    }

    private fun appendEvidence(json: String) {
        // Text/timings only. Never persist microphone bytes in normal operation.
        runCatching {
            val target = File(activity.getExternalFilesDir(null), "vosk-events.jsonl")
            if (target.length() > 1048576) target.writeText("")
            target.appendText(json + "\n")
        }
    }

    private fun digest(file: File): String {
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) { val count = input.read(buffer); if (count < 0) break; hash.update(buffer, 0, count) }
        }
        return hash.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
    }

    private fun preferEfficiencyCores(): String {
        return runCatching {
            val libc = com.sun.jna.NativeLibrary.getInstance("c")
            val mask = com.sun.jna.Memory(128)
            mask.clear()
            check(libc.getFunction("sched_getaffinity").invokeInt(arrayOf(0, com.sun.jna.NativeLong(128), mask)) == 0)
            val allowed = (0 until 1024).filter { mask.getByte((it/8).toLong()).toInt() and (1 shl (it%8)) != 0 }
            val capacities = allowed.mapNotNull { cpu ->
                File("/sys/devices/system/cpu/cpu$cpu/cpu_capacity").readText().trim().toIntOrNull()?.let { cpu to it }
            }.toMap()
            check(capacities.size == allowed.size && capacities.isNotEmpty())
            val lowest = capacities.values.min()
            check(lowest < capacities.values.max())
            mask.clear()
            val efficient = allowed.filter { capacities[it] == lowest }
            for (cpu in efficient) {
                val offset = (cpu/8).toLong()
                mask.setByte(offset, (mask.getByte(offset).toInt() or (1 shl (cpu%8))).toByte())
            }
            val result = libc.getFunction("sched_setaffinity").invokeInt(arrayOf(0, com.sun.jna.NativeLong(128), mask))
            check(result == 0) { "sched_setaffinity=$result" }
            "efficiency_cores=$efficient priority=19"
        }.getOrElse { "scheduler_default priority=19 reason=${it.message}" }
    }

    private fun initialize(): Map<String, Any?> {
        val started = SystemClock.elapsedRealtimeNanos()
        if (cpuPolicy == null) cpuPolicy = preferEfficiencyCores()
        val reused = model != null
        if (!reused) {
            val manifest = JSONObject(activity.assets.open("$MODEL/manifest.json").bufferedReader().use { it.readText() })
            val entries = manifest.getJSONObject("files")
            val target = File(activity.filesDir, MODEL)
            fun valid(directory: File): Boolean = entries.keys().asSequence().all { name ->
                val file = File(directory, name)
                file.isFile && digest(file) == entries.getString(name)
            }
            if (!valid(target)) {
                val temporary = File(activity.filesDir, "$MODEL.partial")
                check(temporary.canonicalFile.parentFile == activity.filesDir.canonicalFile)
                temporary.deleteRecursively(); temporary.mkdirs()
                try {
                    entries.keys().forEach { name ->
                        val file = File(temporary, name)
                        check(file.canonicalPath.startsWith(temporary.canonicalPath + File.separator))
                        file.parentFile?.mkdirs()
                        activity.assets.open("$MODEL/$name").use { input -> file.outputStream().use { input.copyTo(it) } }
                    }
                    check(valid(temporary)) { "Vosk model integrity check failed" }
                    check(target.canonicalFile.parentFile == activity.filesDir.canonicalFile)
                    target.deleteRecursively()
                    check(temporary.renameTo(target)) { "Vosk model installation failed" }
                } finally { temporary.deleteRecursively() }
            }
            model = Model(target.absolutePath)
            val lookup = com.sun.jna.NativeLibrary.getInstance("vosk").getFunction("vosk_model_find_word")
            vocabulary = GRAMMAR.filter { it != "[unk]" }.flatMap { it.split(" ") }.distinct()
                .associateWith { lookup.invokeInt(arrayOf(model!!.pointer, it)) }
            val missing = vocabulary.filterValues { it < 0 }.keys
            if (missing.isNotEmpty()) {
                model?.close(); model = null
                error("Vosk grammar words missing: $missing")
            }
        }
        return mapOf("model" to MODEL, "load_ms" to (SystemClock.elapsedRealtimeNanos()-started)/1e6, "reused" to reused, "vocabulary_ids" to vocabulary, "cpu_policy" to cpuPolicy, "grammar_id" to GRAMMAR_ID)
    }

    private fun replay(pcm: ByteArray, endSeconds: Float?, grammarId: String): Map<String, Any?> {
        initialize()
        val started = SystemClock.elapsedRealtimeNanos()
        Recognizer(model!!, 16000f, JSONArray(if (grammarId == GRAMMAR_ID) GRAMMAR else PHRASES).toString()).use { recognizer ->
            recognizer.setWords(true)
            recognizer.setMaxAlternatives(3)
            // Vosk API parameters use seconds (confirmed against recognizer.cc).
            if (endSeconds != null) recognizer.setEndpointerDelays(3f, endSeconds, 6f)
            val segments = mutableListOf<String>()
            val endpoints = mutableListOf<Map<String, Any?>>()
            var offset = 0
            while (offset < pcm.size) {
                val count = minOf(6400, pcm.size-offset)
                if (recognizer.acceptWaveForm(pcm.copyOfRange(offset, offset+count), count)) {
                    val raw = recognizer.result
                    segments.add(raw)
                    endpoints.add(mapOf("audio_ms" to (offset+count)/32.0, "raw" to raw))
                }
                offset += count
            }
            val tail = recognizer.finalResult
            segments.add(tail)
            return mapOf("grammar_id" to grammarId, "endpoint_end_s" to endSeconds,
                "audio_ms" to pcm.size/32.0, "pcm_sha256" to MessageDigest.getInstance("SHA-256").digest(pcm).joinToString("") { "%02x".format(it.toInt() and 255) },
                "endpoints" to endpoints, "segments" to segments, "tail_raw" to tail,
                "raw" to VoskFinals.merge(segments), "native_compute_ms" to (SystemClock.elapsedRealtimeNanos()-started)/1e6)
        }
    }

    private fun recognize(session: Int, token: Long, startResult: MethodChannel.Result, capture: Boolean) {
        var audio: AudioRecord? = null
        var recognizer: Recognizer? = null
        var acknowledged = false
        try {
            initialize()
            check(epoch.get() == token && !closed) { "Session cancelled" }
            val minimum = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            check(minimum > 0) { "PCM16 16kHz mono unsupported" }
            synchronized(audioGate) {
                check(epoch.get() == token && !closed) { "Session cancelled before microphone acquisition" }
                microphoneOwned = true
            }
            audio = AudioRecord.Builder().setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
                .setAudioFormat(AudioFormat.Builder().setSampleRate(16000).setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setBufferSizeInBytes(maxOf(minimum * 2, 6400)).build()
            check(audio.state == AudioRecord.STATE_INITIALIZED && audio.sampleRate == 16000 && audio.channelCount == 1 && audio.audioFormat == AudioFormat.ENCODING_PCM_16BIT)
            recognizer = Recognizer(model!!, 16000f, JSONArray(GRAMMAR).toString())
            recognizer.setWords(true)
            recognizer.setMaxAlternatives(3)
            recognizer.setEndpointerDelays(3f, ENDPOINT_END_S, 6f)
            val decoder = recognizer
            audio.startRecording()
            check(audio.recordingState == AudioRecord.RECORDSTATE_RECORDING)
            acknowledged = true
            main.post { startResult.success(null) }
            emit(token, mapOf("session" to session, "type" to "listening"))
            val started = SystemClock.elapsedRealtimeNanos()
            val buffer = ByteArray(6400) // 200ms, matching Vosk streaming cadence; PCM16 LE
            var bytes = 0L
            var speechEndAudioMs: Double? = null
            var speechEndWall: Long? = null
            var voicedFrames = 0
            var computeNs = 0L
            val segments = mutableListOf<String>()
            val endpoints = mutableListOf<Map<String, Any?>>()
            val captured = if (capture) ByteArrayOutputStream(MAX_BYTES) else null
            var stopReason = "audio_limit"
            var lastPartial = ""
            fun accept(count: Int): Boolean {
                captured?.write(buffer, 0, count)
                check(count >= 0 && count % 2 == 0) { "AudioRecord error: $count" }
                bytes += count
                var energy = 0.0
                for (i in 0 until count step 2) {
                    val value = ((buffer[i].toInt() and 255) or (buffer[i+1].toInt() shl 8)).toShort().toDouble()/32768
                    energy += value * value
                }
                if (energy / (count/2) >= 0.000016) {
                    voicedFrames += maxOf(1, count/640) // equivalent 20ms units
                    speechEndAudioMs = bytes / 32.0
                    speechEndWall = SystemClock.elapsedRealtimeNanos()
                }
                val inference = SystemClock.elapsedRealtimeNanos()
                val endpoint = decoder.acceptWaveForm(buffer, count)
                computeNs += SystemClock.elapsedRealtimeNanos() - inference
                if (endpoint) {
                    val candidate = decoder.result
                    segments.add(candidate)
                    val text = VoskFinals.text(VoskFinals.merge(segments))
                    val incomplete = text.isNotBlank() && PHRASES.any { it.startsWith("$text ") }
                    endpoints.add(mapOf("audio_ms" to bytes/32.0, "wall_ms" to (SystemClock.elapsedRealtimeNanos()-started)/1e6,
                        "raw" to candidate, "incomplete_phrase" to incomplete))
                    return text.isNotBlank() && !incomplete
                } else {
                    val partial = decoder.partialResult
                    if (partial != lastPartial) {
                        lastPartial = partial
                        emit(token, mapOf("session" to session, "type" to "partial", "raw" to partial))
                    }
                }
                return false
            }
            while (epoch.get() == token && !closed && !stopped && bytes < MAX_BYTES) {
                val count = audio.read(buffer, 0, minOf(buffer.size, MAX_BYTES-bytes.toInt()), AudioRecord.READ_BLOCKING)
                check(count >= 0 && count % 2 == 0) { "AudioRecord error: $count" }
                if (count == 0) { Thread.sleep(5); continue }
                if (accept(count)) { stopReason = "endpoint"; break }
                val elapsed = (SystemClock.elapsedRealtimeNanos()-started)/1e6
                if (elapsed >= 6000) { stopReason = "wall_limit"; break }
                if (speechEndWall == null && elapsed >= 3000) { stopReason = "initial_silence"; break }
            }
            if (stopped) stopReason = "manual_stop"
            // Feed already-buffered PCM before finalResult. Bounded by AudioRecord's
            // actual capacity and the same six-second budget; never wait for new audio.
            var drained = 0
            val drainLimit = minOf(audio.bufferSizeInFrames * 2, MAX_BYTES-bytes.toInt())
            while (epoch.get() == token && !closed && drained < drainLimit) {
                val count = audio.read(buffer, 0, minOf(buffer.size, drainLimit-drained), AudioRecord.READ_NON_BLOCKING)
                check(count >= 0 && count % 2 == 0) { "AudioRecord drain error: $count" }
                if (count == 0) break
                accept(count)
                drained += count
            }
            audio.stop(); audio.release(); audio = null
            synchronized(audioGate) { microphoneOwned = false }
            if (epoch.get() != token || closed) return
            emit(token, mapOf("session" to session, "type" to "processing"))
            val flush = SystemClock.elapsedRealtimeNanos()
            val tail = recognizer.finalResult // Always flush; an endpoint result is only one segment.
            segments.add(tail)
            val raw = VoskFinals.merge(segments)
            computeNs += SystemClock.elapsedRealtimeNanos()-flush
            val finished = SystemClock.elapsedRealtimeNanos()
            val words = JSONObject(raw).optJSONArray("result")
            var alignedEndMs: Double? = null
            if (words != null) for (i in 0 until words.length()) {
                val end = words.getJSONObject(i).optDouble("end", Double.NaN)*1000
                if (end.isFinite() && end >= 0 && end <= bytes/32.0) alignedEndMs = maxOf(alignedEndMs ?: 0.0, end)
            }
            val capturePath = captured?.let {
                val directory = File(activity.getExternalFilesDir(null), "vosk72-audio").apply { mkdirs() }
                File(directory, "${System.currentTimeMillis()}-$session.pcm").apply { writeBytes(it.toByteArray()) }.absolutePath
            }
            val payload = mapOf("session" to session, "type" to "final", "raw" to raw,
                "model" to MODEL, "grammar_id" to GRAMMAR_ID, "endpoint_end_s" to ENDPOINT_END_S,
                "segments" to segments, "endpoints" to endpoints, "tail_raw" to tail,
                "stop_reason" to stopReason, "drained_bytes" to drained, "capture_path" to capturePath,
                "audio_block_ms" to 200, "cpu_policy" to cpuPolicy, "audio_ms" to bytes/32.0, "voiced_frames" to voicedFrames,
                "speech_end_audio_ms" to speechEndAudioMs,
                "after_speech_ms" to alignedEndMs?.let { (finished-started)/1e6-it },
                "speech_end_model_ms" to alignedEndMs,
                "energy_after_speech_ms" to speechEndWall?.let { (finished-it)/1e6 },
                "latency_method" to "Vosk final word alignment relative to recording start; endpoint included; estimate, not external acoustic ground truth",
                "native_compute_ms" to computeNs/1e6, "total_ms" to (finished-started)/1e6)
            recognizer.close(); recognizer = null
            // Clear admission before delivering final; no new audio starts until this worker returns.
            main.post { if (epoch.get() == token) active = false }
            appendEvidence(JSONObject(payload + mapOf("wall_time_ms" to System.currentTimeMillis())).toString())
            emit(token, payload)
        } catch (e: Throwable) {
            if (!acknowledged) main.post { startResult.error("audio", e.message, null) }
            emit(token, mapOf("session" to session, "type" to "error", "message" to (e.message ?: "Vosk error")))
        } finally {
            runCatching { audio?.stop() }; audio?.release(); recognizer?.close()
            synchronized(audioGate) { microphoneOwned = false }
            main.post { if (epoch.get() == token) active = false }
        }
    }

    fun cancel(): Boolean {
        if (worker.isShutdown) return false
        val cancellation = synchronized(audioGate) {
            stopped = true
            epoch.incrementAndGet() to microphoneOwned
        }
        val cancelled = cancellation.first
        val ownsAudio = cancellation.second
        permission = null
        permissionResult?.error("cancelled", "Session cancelled", null)
        permissionResult = null
        // Queued behind the read loop: new sessions cannot overlap microphone cleanup.
        if (!ownsAudio) active = false
        else worker.execute { main.post { if (epoch.get() == cancelled) active = false } }
        return ownsAudio
    }

    override fun close() {
        if (closed) return
        closed = true; cancel()
        channel.setMethodCallHandler(null); events.setStreamHandler(null); sink = null
        worker.execute { model?.close(); model = null }
        worker.shutdown()
    }

    companion object {
        const val PERMISSION_REQUEST = 907
        const val MODEL = "vosk-model-small-ru-0.22"
        const val GRAMMAR_ID = "v2-context-guards"
        const val MAX_BYTES = 192000
        const val ENDPOINT_END_S = 0.9f
        val PHRASES = listOf("начать", "начни", "запусти", "закончить", "останови", "стоп",
            "что впереди", "что передо мной", "опиши окружение", "опиши обстановку", "что вокруг", "[unk]")
        // Preserve negation/question context instead of projecting it onto a command.
        // These phrases are recognisable but NEVER routable actions.
        val REJECTIONS = listOf("не", "нет", "как", "почему", "когда", "надо", "нужно", "можно",
            "это", "я", "мы", "ты", "вы", "он", "она", "они", "не начинай", "не начинать",
            "не останавливай", "не останавливать", "не надо", "как начать", "как остановить")
        val GRAMMAR = PHRASES + REJECTIONS
    }
}
