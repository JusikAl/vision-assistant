# Whisper Offline Integration — 2026-11-18

Status: integrated, **not accepted**. The synthetic accuracy target of 90% is
not met; live human acceptance is pending. The user agreed to perform the 40 spoken-command attempts on the phone.
Do not equate synthetic speech results with microphone/human command accuracy.

## Implementation

- `lib/services/whisper_service.dart`: bounded 16 kHz mono PCM16 recording via the
  existing record package, up to five seconds; 20 ms RMS endpoint windows with
  800 ms trailing silence. No streaming Whisper or audio files accumulate.
- `WhisperBridge.kt` and `whisper_jni.cpp`: one reusable native Tiny context,
  dedicated single Android executor, one CPU inference thread at inherited
  lowest scheduling priority. Where CPU capacities are readable and differ,
  only that worker is affined to the allowed lowest-capacity cores; the YOLO
  threads and process affinity are unchanged. On this device that is mask 0x0f
  (cores 0?3). On uniform/unknown topology the normal scheduler is retained. Model extraction, verification, loading and
  inference occur away from the Android main thread. GGML kernels explicitly
  use -O3 even when Flutter profile selects native Debug configuration.
- `whisper.cpp` v1.9.5 is pinned at
  `d1be6fde11ac6e0407606b4e42fe72d34add8037`, vendored with its MIT license.
  Native inference is CPU-only, no cloud API, GPU, Python or server on Android.
- The encoder context is bounded to 512 steps (10.24 seconds) for recordings
  capped at five seconds. Beam search (5 beams) and timestamp decoding are enabled. Whole repeated
  identical commands are normalized only when every token matches; incomplete
  repetitions, mixed requests and negations remain unknown.
  Timestamp tokens are not returned as speech text. A short Russian domain vocabulary
  is supplied as the initial decoder prompt; it is not a forced grammar. Inputs
  still need sufficient PCM energy, avg log probability >= -1 and no-speech
  probability <= 0.6, followed by exact command parsing. These scores are not
  calibrated probabilities of a correctly executed command.
- Native abort callbacks plus session generations invalidate cancelled/old
  transcripts. Only one inference may be active, including after a timeout;
  timeout does not make another native job eligible until the old job exits.
  Dispose frees the context after active native work, and an engine can load
  again for a later page session. Activity stop also invalidates native work.
- Recording operations are serialized. TTS cancels recording and inference
  before taking audio. Informational priority-1 narration is deferred during a
  voice operation; priority-2 and priority-3 alerts remain eligible, with the
  existing TTS scheduler/expiry/preemption. YOLO and Safety evaluation are never
  disabled by Whisper. Cancellation does not wait for inference before TTS.
- Recorder failure cannot leave an unresolved command future. A failed native
  microphone stop blocks further capture until recreation; TTS and visual
  Start/Stop remain available. Rapid cancellation cannot overwrite newer state.
- Exact Russian phrase parsing supports Start, Stop, Describe, Repeat, aliases,
  punctuation/case/spacing, whole identical repetitions, and preserved exact
  warning/help commands. Substring
  and arbitrary `опиши ...` execution were removed. Unknown transcripts return
  `Команда не распознана`; no speech/low confidence does not execute a command.
- Description uses `SceneDescriptionSource`, currently backed by fresh confirmed
  Smart Scene Analyzer results. A future VLM router can implement this interface
  independently of STT. The same `activateVoiceCommand()` entrypoint can be called
  from a future wake-word adapter. No new OpenWakeWord or VLM integration is made.
- Repeat uses the most recent native-started TTS text, labels it as historical,
  and does not overwrite history with another repeat prefix.

## Model and build

Bundled file: `assets/models/ggml-tiny.bin`, Tiny **Multilingual**, not tiny.en or a
quantized variant. Size: 77,691,713 bytes. SHA256:
`be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21`.
`pubspec.yaml` includes the model as an asset. The Android worker extracts it
atomically to app-private files, verifies its digest, then reuses one context.
Extraction is recovered on a subsequent initialization if interrupted. Missing,
corrupt or incompatible models produce an error and leave UI detection usable.
The app contains no runtime model downloader.

Source model: https://huggingface.co/ggerganov/whisper.cpp/blob/main/ggml-tiny.bin
Source runtime: https://github.com/ggml-org/whisper.cpp/tree/v1.9.5

To restore an absent model on the development computer:

```powershell
Invoke-WebRequest 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin' -OutFile assets/models/ggml-tiny.bin
Get-FileHash assets/models/ggml-tiny.bin -Algorithm SHA256
flutter build apk --release --target-platform android-arm64 --dart-define=OFFLINE_ONLY=true
```

Verify the hash above before building. Internet is needed to obtain development
sources/model initially, not to recognize commands after APK installation. The
Android build includes ARM64 native binaries. NDK 28.2.13676358, CMake 3.22.1 and
Java 17 are used in this workspace. Existing Kotlin plugin migration warnings
from flutter_tts/record_android are unrelated to this integration.

The previous `VoiceCommandService`, speech_to_text dependency, tests and existing
Hey Jarvis service/assets remain. `--dart-define=LEGACY_VOICE=true` selects the
previous activation/recognition path for a compatibility build. There is no
silent fallback from Whisper to a potentially networked system recognizer.

## Automated tests

`flutter test`: **105 tests passed**. `flutter analyze`: **no issues**.
Coverage includes no-speech, silence endpoint/max duration, denied permission,
recording interruption, repeated activation, cancellation during model load,
recorder opening and inference, timeout without queued work, resource cleanup,
failed microphone stop, stale cancellation against a newer session, exact command
routing, scene-source failure, repeat history, priority-1 deferral and critical
TTS eligibility. The prior 84-test Safety/YOLO suite continues to pass.

## Android validation

Harness: `tool/whisper_device_smoke.dart`; fixture synthesis helper exists only
in `android/app/src/profile`, and is absent from release. It uses an installed
network-independent Russian Android TTS voice and generates WAV files into a
single reused temporary cache path. WAVs are converted to PCM16 mono/16kHz, with
rate variation, attenuation and added noise. No cloud transcription is involved.
These are synthetic electrical fixtures, not spoken human attempts or an
acoustic loudspeaker-to-microphone test.

The main run disables Wi-Fi and mobile data on the CPH2727 device and keeps the
screen awake. Original radio/timeout settings are saved and restored afterwards.

The harness checks 10 attempts per command, then measures counterbalanced
inactive/active/active/inactive Whisper CPU windows while the camera and YOLO
remain running. The model remains resident in both conditions. Silence, actual
recorder cancellation and repeated detection Start/Stop are also checked. No
fixture is allowed to cause arbitrary UI commands; parsing accuracy and command
handler execution are validated separately, with live end-to-end tests below.

Results and remaining issues are appended after the final device run.

## Live human acceptance checklist

On the installed main application, Wi-Fi and mobile data off:

1. Tap the microphone, wait for Listening, speak the command; wait for the reply.
2. Say each of `Начать`, `Остановить`, `Что впереди?`, `Повтори` ten times, mixing
   supported aliases and quiet/normal speech. Include moderate real room noise.
3. Record expected action, actual transcript/action, condition and latency for
   every attempt; report success counts per command and in total (goal >=90%).
4. Check no speech, unknown/negated phrases, second-tap stop/cancel, backgrounding
   the app, permission refusal, multiple Start/Stop cycles and warnings while
   recording. Use benign scenes; synthetic hazards do not validate real recall.
5. Verify Repeat explicitly says it is a previous message. Describe must reject
   stale data and must not claim a free path when no objects are detected.

Native engine-start timings are not acoustic latency measurements. Camera frame
callbacks also exclude time before Dart delivery. Controlled CPU competition
measurements do not prove accuracy or latency in every scene/thermal condition.

## Measured results and acceptance gates

Device: CPH2727, Android 16 ARM64, profile mode. Wi-Fi and mobile data were both
verified off. All measurement entrypoints finished with `WHISPER TEST complete`.
The actual recorder opened and cancellation returned null/Idle, both before and
after CPU-affinity adjustment. Camera Start/Stop cycles also completed. Silence
returned no transcript. Four synthetic unknown/negative probes remained unknown;
these checks do not establish a general false-activation rate.

### Accuracy gate: NOT MET

The 40 synthetic native Android transcripts were collected before the final
CPU-affinity adjustment, using the same model, prompt, beam search and context.
Sixteen operations returned no transcript after cancellation/not starting while
Safety/TTS remained eligible. The original on-device parser accepted 13/40.
The current parser's exact whole-repeat normalization was subsequently checked
against the saved transcripts with `dart tool/whisper_transcript_replay.dart`:
**19/40 (47.5%)** overall, **19/24 (79.2%)**
among operations that returned a native result. This replay is a pure Dart
classification check, NOT an Android UI action or a live spoken-command test.

| Command | Matches in replay / attempts |
| --- | ---: |
| Start | 5/10 |
| Stop | 5/10 |
| Describe | 4/10 |
| Repeat | 5/10 |

Examples of rejected ASR errors include `Повторит.` instead of `Повторить` and
`Стоп передо мной.` instead of `Что передо мной`. The handler deliberately does
not guess these as valid commands. Complete repeated phrases are accepted only
when they comprise the entire transcript; unrelated or partial phrases remain
unknown. No approximate/fuzzy matching was introduced to inflate the score.

**The project's >=90% target has not been achieved.** The user has agreed to
perform the required 10 live attempts per command after installation. Human
microphone accuracy, genuine quiet speech/background noise, permission refusal
on the physical device, and live end-of-command-to-action latency remain open.
A satisfactory live result must be documented before accepting this stage.

### Recognition latency

Model initialization in the 40-fixture run: native 592.368 ms; first extraction
in an earlier cold run took about 5.6 seconds, including installation/verification.
The same context was reused for later calls. These are different populations.

Completed native calls BEFORE affinity adjustment: n=24, p50 **9350.686 ms**,
p95 **10337.473 ms**, max 10381.488 ms. Cancellations are excluded from those
latency quantiles. They must not be presented as final post-affinity latency:
restricting the worker to smaller cores can increase recognition time. Final
human/microphone latency distribution remains to be measured. The 20-second
native-call watchdog remains enabled; inference timeout does not stop YOLO.
Synthetic file-to-text timing is not acoustic end-of-speech latency.

### YOLO competition gate

Before efficiency-core placement, paired pooled throughput was 4.199/s
inactive and 3.473/s active (**17.28% drop**). One background
thread plus lowest scheduling priority alone did not meet the 10% limit.

The final worker successfully applied efficiency mask `0x0f` (CPU capacity 611,
cores 0?3, versus capacity 1024 on cores 4?7). Only the Whisper thread is affected.
YOLO still uses its existing four threads, model and CameraX path; Safety runs
throughout. Counterbalanced 20-second windows after the change:

| Window | Whisper inference | New YOLO results/s | CameraImage-to-result p50/p95 | RSS at window end |
| --- | --- | ---: | ---: | ---: |
| 1 | idle | 4.847 | 165.988 / 244.445 ms | 513.7 MiB |
| 2 | active | 4.398 | 182.702 / 285.529 ms | 511.7 MiB |
| 3 | active | 4.148 | 196.619 / 258.708 ms | 520.6 MiB |
| 4 | idle | 4.499 | 173.140 / 265.383 ms | 520.8 MiB |

Pooled rates (total new results / total measurement time, not averaged UI FPS):
**4.673/s idle**, **4.273/s active**, **8.57% observed drop**. This
particular comparison is below the 10% project limit. The model is resident in
both modes. Window-specific quantiles are not pooled or averaged. RSS values are
samples, not a measured peak. Longer live workloads and other devices can differ;
no claim of universally <=10% degradation is made.

### Artifact and reproducibility

Main release APK: `build/app/outputs/flutter-apk/app-release.apk`, 176,787,350 bytes.
SHA256: `17bdc1c38b359573c7ec5b77356860897d7d90179de588e52c5c44635e5e3535`.
Release build succeeded. Profile-only fixture helper is not in release sources.

Raw structured evidence: `whisper_android_validation.json`. Local ignored logs:
`whisper_acceptance.log`, `whisper_efficiency_validation.log`,
`whisper_release_ready.log`, `whisper_tests_ready.log`, `whisper_analyze_ready.log`.

```powershell
flutter run --profile -t tool/whisper_device_smoke.dart --dart-define=OFFLINE_ONLY=true -d <device>
flutter run --profile -t tool/whisper_device_smoke.dart --dart-define=OFFLINE_ONLY=true --dart-define=WHISPER_PERF_ONLY=true -d <device>
dart tool/whisper_transcript_replay.dart
```

Test radio and screen settings are restored to their saved original values after
measurement. The normal main-entrypoint release APK replaces the fixture build
on the phone, retaining app data. This is a development APK using the repository's
existing debug signing configuration, not a store-signed distribution.

Release UI smoke: the main APK loaded `libnavigation_whisper.so` successfully
and initialized Tiny in 695.345 ms. A microphone-button activation followed by
Home/resume returned to the idle command UI; no native linker/fatal error was
observed in the checked app log. The normal app is left on screen with detection
stopped and the microphone idle for the user’s manual acceptance run.

## Live diagnostic repair session — 2026-11-20 (in progress)

Separate entrypoint: `flutter run --profile -t tool/whisper_diagnostic.dart -d d162aebf`.
No camera, TTS, or command execution is started by this entrypoint. Raw native
text is shown before confidence filtering or routing. Parser matching is reported
separately as `command_matched`; it is not proof of an executed action.

Original captured bytes are saved as WAV PCM16 LE / 16000 Hz / mono under the
app external-files `whisper-diagnostics` directory. Each successful run has an
adjacent JSON containing expected phrase, raw text, native inference and audio
preparation time, recording duration, total wall latency, sample count, peak,
clipping, memory RSS sample and configuration. Replay reuses captured bytes.
Model SHA256 verified locally:
`be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21`.
Native conversion uses signed little-endian int16 divided by 32768.0f, passing
exactly byte_count/2 floats. Russian, translate=false, no_context=true remain set.
Diagnostic decoding disables the existing vocabulary prompt; production defaults
remain unchanged pending measurements. CPU efficiency affinity remains enabled.

Protocol: record each of Начать / Остановить / Что впереди? / Повтори with Tiny,
2 threads, beam=5, audio_ctx=512. Replay each recording changing only threads to
4. Then restore 2 threads and compare greedy; separately compare audio_ctx=0.
Listen to exported WAV before attributing errors to the model. Only after good
quality Tiny failures should Base Multilingual be evaluated on identical WAVs.
Camera-active and actual action/warning-priority acceptance remain required.
No new live accuracy or final configuration is claimed yet.

Validation so far: 18 Whisper/handler unit tests passed; diagnostic Dart analysis
passed; diagnostic profile APK compiled including Kotlin/JNI. Device CPH2727
connected after initial implementation. Build success does not satisfy acceptance.
