# Performance optimization v3 — 2026-11-16

Changes extend the existing application and preserve earlier uncommitted work.
No model, dependency or delegate was replaced.

## Changes

- Persistent YOLO worker, preload, warm-up and interpreter reuse remain intact.
  Existing one-in-flight backpressure drops incoming frames before copying NV21;
  the next available callback supplies a fresh frame. No pending frame FIFO.
  Inference errors stop detection explicitly instead of restarting indefinitely.
- NV21 preprocessing clears only letterbox pixels in the reusable Float32 buffer,
  avoiding a full fill before overwriting the image. Sampling, rotation, 320×320
  input, tensor validation and decoding remain unchanged.
- Safety retains confidence, spatial/temporal confirmation, side hysteresis,
  freshness and metric-depth validation. Empty detections do not establish a
  safe path. Offline warnings contain no invented meters.
- TTS cooldown is recorded on engine start or successful completion. Failed
  synthesis clears its cooldown and uses a separate two-second backoff, avoiding
  suppression of a failed critical warning for twelve seconds. Native stop still
  precedes the next utterance. Idle Stop no longer calls an unconnected Android
  engine. Existing priorities, preemption, expiry and offline voice selection stay.
- Before speech, await recognition cancellation and stop the existing wake
  recorder. YOLO does not await speech. After speech, schedule wake listening
  with a 350 ms delay. Stop during wake initialization/permission lookup now
  invalidates that start. Existing openWakeWord was preserved, not introduced.
- STT listen/cancel/stop/release operations are serialized. Cancel invalidates
  pending starts immediately; old results are ignored. One recognizer and one
  initialization future are reused. Explicit Idle/Listening/Processing/Speaking/
  Error state and dictation mode support longer commands. Existing watchdog and
  final-partial fallback remain. Consecutive command failures back off wake
  resumption (1.8, 3.6 seconds), then disable automatic listening after three
  failures. Manual restart resets the budget.
- A separate Russian parser handles Start/Stop/Describe aliases, punctuation,
  whitespace, ё/е and polite forms without VLM. Added «Закончи» and «Выключи
  детекцию». Exact action phrases avoid substring and negation matches. Existing
  help/repeat/warning switches and scene descriptions remain.
- Removed duplicate Android RECORD_AUDIO/INTERNET declarations; permissions and
  recognition/TTS package queries remain.

## Debug/profile report

`NAV PERF` emits aggregates every five seconds: p50/p95 and sample count, bounded
to 120 values per metric. The timer and frame-timing callback are removed on
dispose. The reporter is disabled in release.

| Metric | Meaning |
| --- | --- |
| camera_fps | All Dart camera callbacks per window, including dropped frames |
| yolo_fps | Accepted results per window, separately from camera/native invoke FPS |
| inference_ms, preprocess_ms | Offline worker stages |
| safety_ms | Mobile safety evaluation and queue update |
| tts_response_ms | Speak submission to engine start callback, not speech duration |
| confirmed_to_speech_ms | First confirmed scene observation to engine start, including handover/queueing |
| voice_recognition_ms | Listen session to transcript, including user speech and endpointing |
| detect_startup_ms | Start to first accepted result |
| ui_build_ms, ui_raster_ms | Flutter FrameTiming for rendered frames |

Speech metrics enter once per event, not repeatedly on camera frames. Online
result FPS and mobile safety are counted; server YOLO/depth fields remain in the
UI. Confirmed-to-speech excludes the earlier confirmation frames and is not an
acoustic measurement. Native sensor capture latency and pure ASR compute latency
are not exposed by the current plugins. Existing sampled worker logs remain;
no additional per-frame production log was added.

## Acceleration and offline speech

Retain previously validated Android XNNPACK/4 threads and CPU fallback. Earlier
CPU/XNNPACK timings and parity checks are in
[offline_yolo_performance.md](offline_yolo_performance.md), not v3 measurements.
NNAPI/GPU remain disabled: no new driver/accuracy validation justifies enabling
them.

`speech_to_text` uses the system recognizer. Default recognition remains as
before. `--dart-define=STT_ON_DEVICE=true` requests on-device recognition for
validation; it installs no ASR model and proves no offline availability. A Russian
locale listing alone does not establish that offline language data is present.
Android documents that EXTRA_PREFER_OFFLINE may have no effect depending on the
recognizer. Test with network unavailable and installed Russian language data.
Buttons, offline YOLO, Safety and installed local Russian TTS do not require STT.

Sources: [Android RecognizerIntent](https://developer.android.com/reference/android/speech/RecognizerIntent#EXTRA_PREFER_OFFLINE),
[speech_to_text](https://pub.dev/packages/speech_to_text),
[ListenMode](https://pub.dev/documentation/speech_to_text/latest/speech_to_text/ListenMode.html).

## Verification

- `C:/dev/flutter/bin/dart.bat format lib test`: completed.
- `flutter analyze`: no issues.
- `flutter test`: 64 passed, including existing safety/depth/freshness, worker
  reuse/cancellation/failure and TTS queue/priority/cooldown tests. New coverage:
  parser, STT races, failed-warning retry, audio handover, idle Stop, stale
  critical evidence and full-buffer NV21 reuse across rotations/layouts.
- Profile APK built and installed on CPH2727, Android 16, arm64.
- Hardware initialization sample: asset 1.80 ms, interpreter 187.65 ms, warm-up
  1000.57 ms, total preload 1316.47 ms; XNNPACK active. Local Russian voice
  ru-ru-x-ruf-local selected with network_required=false. These are initialization
  samples, not camera throughput. The initial idle TTS Stop timeout was reproduced
  and fixed; it did not recur in the second profile launch.
- Initial camera smoke could not finish: phone asleep with keyguard showing, camera
  callbacks stayed at zero, Flutter connection lost. No valid v3 camera FPS,
  obstacle-to-speech latency, spoken command accuracy or before/after comparison
  was available from those attempts. Live server/Depth/VLM integration
  and real-world warning accuracy were not exercised.

Ignored local evidence in `build/yolo_diagnostics/`: `v3_tests.log`,
`v3_camera_smoke.log` (initial failure), `v3_camera_smoke_final.log` (second run),
`v3_main_profile.log` (normal entrypoint restoration).

Follow-up after the user reported the screen was enabled: the new profile smoke
launch also saw `mCurrentFocus=NotificationShade`, `isKeyguardShowing=true` and
zero camera callbacks. This attempt does not supply a camera performance result.
Evidence: `v3_unlocked_smoke.log`; normal entrypoint restoration:
`v3_unlocked_main.log`.

## Completed follow-up with the phone unlocked

The user subsequently unlocked CPH2727. ADB confirmed Awake, keyguard=false and
MainActivity in the foreground. Tested the installed normal `lib/main.dart`
profile build using actual UI Start/Stop taps, with offline-only and voice
warnings enabled. No new installation or model change during these cycles.

| Cycle | Start to first result, ms | Camera FPS, full running windows | YOLO results/s, full running windows |
| --- | ---: | ---: | ---: |
| 1 | 3539.10 | 11.34–14.19 | 0.40–0.80 |
| 2 | 2736.58 | 12.62–13.37 | 0.40–0.60 |
| 3 | 5458.63 | 10.42–13.00 | 0.20 |

Windows are five seconds; partial windows overlapping Start/Stop are excluded
from the ranges. Native stream-start API completion was 0.85/0.89/1.01 ms,
which is not first-result latency. Zero OFFLINE INIT events during the three
cycles, zero OFFLINE YOLO ERROR events. The interpreter was retained.

Observed offline invoke times were much slower than earlier recorded device
measurements: roughly 0.8–2.7 seconds in sampled first-cycle frames, and
3.6–5.9 seconds in third-cycle report samples. This run does not demonstrate a
performance improvement. It reveals a performance limitation under these device
conditions. Safety rejects results older than its existing freshness threshold;
slow results must not be treated as current obstacle evidence.

Context: Android thermal status LIGHT (1), shell skin 39°C, battery 36°C. A single
top snapshot showed only ~16 MB free physical memory (cache reclaimability is not
represented by that figure), ~2.58 GB swap used and kswapd0 ~56% CPU. Java logs
show repeated GC collections of tens of MB and thread suspension. These are
evidence of allocation/memory pressure, not proof of a unique root cause or a
memory leak. Camera stream is 1280×720 NV21; full-resolution native frame
conversion/delivery remains a candidate bottleneck before Dart backpressure.
No camera/model resolution or delegate default was changed on this evidence.

UI build p50 remained around 0.36–0.50 ms during running windows. No confirmed
obstacle/TTS WARNING event occurred, so obstacle-to-speech/TTS response latency
and recognition accuracy remain unmeasured on hardware. Do not infer that voice
warnings or safe navigation were validated by this throughput test.

Final UI dump confirms Status: Stopped, MODE: NO DETECTION, Start Detection.
The original stay_on_while_plugged_in setting (0) was restored after temporarily
keeping the screen awake. Normal entrypoint remains installed.

Evidence: `build/yolo_diagnostics/v3_live_buttons.log`, `v3_final_ui.xml`,
`v3_thermal.txt`. These measurements supersede the earlier absence of camera
results, but do not provide a controlled before/after comparison.

Reproduce with the phone unlocked:

```powershell
flutter run --profile -d d162aebf -t tool/yolo_camera_smoke.dart --dart-define=OFFLINE_ONLY=true
# Three automatic Start/Stop cycles, then restore the normal entrypoint:
flutter run --profile -d d162aebf -t lib/main.dart --dart-define=OFFLINE_ONLY=true
# Optional device-dependent offline STT check:
flutter run --profile -d d162aebf --dart-define=OFFLINE_ONLY=true --dart-define=STT_ON_DEVICE=true
```

For warning latency, present a supported obstacle until temporal confirmation,
inspect speech-event samples, and check critical preemption during a scene
description. A run without a confirmed obstacle gives no warning-latency value.
