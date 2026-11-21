#include <jni.h>
#include <chrono>
#include <whisper.h>
#include <atomic>
#include <cmath>
#include <string>
#include <vector>
#include <fstream>
#include <sched.h>
#include <climits>
#include <android/log.h>

static void prefer_efficiency_cores() {
    static thread_local bool attempted = false;
    if (attempted) return;
    attempted = true;
    cpu_set_t allowed, efficient;
    CPU_ZERO(&allowed); CPU_ZERO(&efficient);
    if (sched_getaffinity(0, sizeof(allowed), &allowed) != 0) return;
    int capacity[CPU_SETSIZE] = {}, lowest = INT_MAX, highest = 0;
    for (int cpu = 0; cpu < CPU_SETSIZE; ++cpu) {
        if (!CPU_ISSET(cpu, &allowed)) continue;
        std::ifstream file("/sys/devices/system/cpu/cpu" + std::to_string(cpu) + "/cpu_capacity");
        file >> capacity[cpu];
        if (capacity[cpu] > 0) { lowest = std::min(lowest, capacity[cpu]); highest = std::max(highest, capacity[cpu]); }
    }
    if (lowest >= highest) {
        __android_log_print(ANDROID_LOG_INFO, "WhisperCPU", "Topology unavailable/uniform; retaining scheduler affinity");
        return;
    }
    unsigned long mask = 0;
    for (int cpu = 0; cpu < CPU_SETSIZE; ++cpu) {
        if (capacity[cpu] == lowest) { CPU_SET(cpu, &efficient); if (cpu < 32) mask |= 1UL << cpu; }
    }
    const int result = sched_setaffinity(0, sizeof(efficient), &efficient);
    __android_log_print(ANDROID_LOG_INFO, "WhisperCPU", "efficiency_mask=%lx result=%d", mask, result);
}

// Only cancellation touches this from the platform thread. Context operations
// and destruction are serialized by the Kotlin executor.
static std::atomic<int64_t> epoch{0};
static bool aborted(void * data) {
    return epoch.load() != *static_cast<int64_t *>(data);
}
extern "C" JNIEXPORT jlong JNICALL
Java_com_example_camera_WhisperBridge_nativeEpoch(JNIEnv *, jobject) {
    return epoch.load();
}
extern "C" JNIEXPORT void JNICALL
Java_com_example_camera_WhisperBridge_nativeCancel(JNIEnv *, jobject) {
    ++epoch;
}
extern "C" JNIEXPORT jlong JNICALL
Java_com_example_camera_WhisperBridge_nativeLoad(JNIEnv * env, jobject, jstring path) {
    const char * name = env->GetStringUTFChars(path, nullptr);
    auto params = whisper_context_default_params();
    params.use_gpu = false;
    auto * ctx = whisper_init_from_file_with_params(name, params);
    env->ReleaseStringUTFChars(path, name);
    if (ctx && (!whisper_is_multilingual(ctx) || whisper_model_n_audio_layer(ctx) != 4)) {
        whisper_free(ctx);
        ctx = nullptr;
    }
    return reinterpret_cast<jlong>(ctx);
}
extern "C" JNIEXPORT void JNICALL
Java_com_example_camera_WhisperBridge_nativeFree(JNIEnv *, jobject, jlong handle) {
    if (handle) whisper_free(reinterpret_cast<whisper_context *>(handle));
}
extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_example_camera_WhisperBridge_nativeTranscribe(
    JNIEnv * env, jobject, jlong handle, jbyteArray pcm, jlong token, jint threads, jboolean greedy, jboolean fullContext, jboolean diagnostic) {
    const auto prepared = std::chrono::steady_clock::now();
    auto * ctx = reinterpret_cast<whisper_context *>(handle);
    const int size = env->GetArrayLength(pcm);
    if (!ctx || size < 6400 || size > 160000 || size % 2) return nullptr;
    std::vector<jbyte> bytes(size);
    env->GetByteArrayRegion(pcm, 0, size, bytes.data());
    std::vector<float> audio(size / 2);
    for (int i = 0; i < size / 2; ++i) {
        const auto sample = static_cast<int16_t>(
            static_cast<uint8_t>(bytes[2*i]) | (static_cast<uint8_t>(bytes[2*i+1]) << 8));
        audio[i] = sample / 32768.0f;
    }
    int64_t request = token;
    if (aborted(&request)) return nullptr;
    prefer_efficiency_cores();
    auto params = whisper_full_default_params(greedy ? WHISPER_SAMPLING_GREEDY : WHISPER_SAMPLING_BEAM_SEARCH);
    params.n_threads = threads; // background priority; YOLO retains its four threads
    params.language = "ru";
    // Domain vocabulary is a decoder prompt, not a grammar forcing a command.
    // Energy/no-speech/logprob gates and exact Dart routing still apply.
    params.initial_prompt = "Русские голосовые команды. Начать. Начни. Запусти. Начать обнаружение. Остановить. Останови. Стоп. Остановить обнаружение. Что впереди? Что передо мной? Что ты видишь? Опиши окружение. Повтори. Повторить. Ещё раз. Скажи снова.";
    if (diagnostic) params.initial_prompt = nullptr;
    params.translate = false;
    params.no_context = true;
    params.no_timestamps = false;
    params.single_segment = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.suppress_nst = true;
    params.temperature = 0;
    params.temperature_inc = 0;
    params.greedy.best_of = 1;
    params.beam_search.beam_size = 5;
    params.max_tokens = 24;
    params.audio_ctx = 512; // 10.24s encoder context for <=5s command recordings
    if (fullContext) params.audio_ctx = 0;
    params.abort_callback = aborted;
    params.abort_callback_user_data = &request;
    const auto inference = std::chrono::steady_clock::now();
    if (whisper_full(ctx, params, audio.data(), audio.size()) != 0 || aborted(&request)) return nullptr;
    const auto finished = std::chrono::steady_clock::now();
    std::string text;
    double logprob = 0, noSpeech = 0;
    int tokens = 0;
    for (int s = 0; s < whisper_full_n_segments(ctx); ++s) {
        text += whisper_full_get_segment_text(ctx, s);
        noSpeech = std::max(noSpeech, double(whisper_full_get_segment_no_speech_prob(ctx, s)));
        for (int t = 0; t < whisper_full_n_tokens(ctx, s); ++t) {
            if (whisper_full_get_token_id(ctx, s, t) >= whisper_token_eot(ctx)) continue;
            logprob += std::log(std::max(1e-8f, whisper_full_get_token_p(ctx, s, t)));
            ++tokens;
        }
    }
    auto strings = env->FindClass("java/lang/String");
    auto result = env->NewObjectArray(5, strings, nullptr);
    const std::string fields[] = {text, std::to_string(tokens ? logprob / tokens : -100), std::to_string(noSpeech),
        std::to_string(std::chrono::duration<double, std::milli>(inference-prepared).count()),
        std::to_string(std::chrono::duration<double, std::milli>(finished-inference).count())};
    auto constructor = env->GetMethodID(strings, "<init>", "([BLjava/lang/String;)V");
    auto encoding = env->NewStringUTF("UTF-8");
    for (int i = 0; i < 5; ++i) {
        auto bytes = env->NewByteArray(fields[i].size());
        env->SetByteArrayRegion(bytes, 0, fields[i].size(), reinterpret_cast<const jbyte *>(fields[i].data()));
        auto value = env->NewObject(strings, constructor, bytes, encoding);
        env->SetObjectArrayElement(result, i, value);
        env->DeleteLocalRef(value);
        env->DeleteLocalRef(bytes);
    }
    return result;
}
