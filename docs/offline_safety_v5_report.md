# Offline Safety v5 — 2026-11-17

Status: core offline validation completed; integration limits are listed below.
Device: CPH2727, Android 16 ARM64, profile mode, original high-resolution
1280×720 NV21 camera path. No hazardous road testing was performed.

## Preserved v4

Original FP32 YOLO11n, 320×320 input, XNNPACK/4 threads, CameraX early admission
and single-plane NV21 are retained. Model SHA256:
`81e210968f0706d1fc1d78ab43ab4cc1e491a4a11eb7b691f3c1e7a4768f6386`.
Local CameraX 0.7.6 sources, Pigeon schema, generated bindings, BSD LICENSE and
LOCAL_CHANGES.md are tracked by Git. pubspec and lockfile use the local override.
A profile build succeeds with this copy and the installed SDK. A cache-free,
network-free clean build has not been demonstrated. The production Java NV21
packer passes 600 geometry/padding/stride/ownership cases.

## Confirmed problem and fix

After asynchronous microphone release, TTS checked cancellation but did not
recheck evidence age or whether the warning still existed in the current scene.
A delayed audio handoff could submit expired evidence before the expiry timer
ran. Before native speak, freshness and current scene membership are now checked
again. Two regression tests cover expiry and disappearance during handoff.
The working TTS engine, voice selection and queue policy were retained.

A second source-audit finding was that the manual scene description ignored
lastResult age. It now rejects missing, future-dated or older-than-1500-ms
results. Descriptions explicitly refer to the last processed frame; repeat
commands explicitly identify previous messages/warnings, rather than presenting
old cached text as a new current observation. Manual messages can still wait
up to the existing four-second message TTL; their historical wording is
intentional. This path was source-reviewed; an end-to-end Russian spoken-command
test was not completed in this session.

## Timing definitions

- CameraImage → result: accepted Dart CameraImage callback to local YOLO return;
  excludes sensor/CameraX/native packing before Dart delivery.
- Result → confirmation: first result of a stable track to its first Safety
  confirmation, including waiting for subsequent inference. Two frames and at
  least 120 ms are required. CPU evaluation duration is a separate metric.
- Confirmation → TTS: first track confirmation to native TTS start callback,
  including audio handoff and queueing.
- CameraImage → TTS: first CameraImage of that track to native start callback,
  including temporal confirmation. This is observed software-chain latency,
  not latency from physical obstacle appearance or an acoustic measurement.
- Originating confirming evidence age at speech start is logged separately. Cooldown repeats
  are marked and must not be pooled with first-response latency samples.

Timestamps use application DateTime; system clock changes during testing were
not exercised. Native start callback does not establish the audible onset.
No empty scene implies a clear path. No unverified distance in metres is spoken.

## Automated scenarios and policy audit

Tests cover person/car/stairs/chair, left/center/right, hysteresis, priority
3/2/1, multiple objects, independent same-class matching, transient detections,
disappearance, invalid geometry/confidence, stale frames, slow inference and
camera pauses. Empty scenes produce no alerts. No model classes were added.

Cooldown is 12/20/30 seconds for priority 3/2/1. Frame age above 1500 ms resets
temporal evidence; result gaps above 1500 ms cannot confirm a track. Pending
warnings disappear with the scene. Active evidence expires at 1800 ms; one missed
frame alone does not immediately cut a short phrase.

TTS tests cover important-warning interruption of descriptions after native stop,
single voice ownership, cooldown, failed stop, missing offline voice, recovery,
nonblocking onDetections and microphone release before native speak. Worker
tests cover Start/Stop cancellation, busy admission until the actual reply, and
worker reuse. STT tests cover cancellation during initialization, stale callbacks
and TTS exclusion. Physical audio conflicts and buttons with unavailable STT
need separate device evidence.

| Scenario | Host evidence | Device evidence / limitation |
| --- | --- | --- |
| Obstacle ahead | temporal person/car/stairs/chair tests | chair/person warnings; informal user check |
| Moves left/right | chair boundary motion and hysteresis | chair/person warnings in all directions |
| Disappears | queue replacement, evidence expiry, handoff regression | user reported no issues; no frame-by-frame annotation |
| Brief false detection | one frame never confirms | no labeled physical false-positive experiment |
| Several objects | priority ordering and same-class matching | chair/person messages; no exhaustive ground truth |
| Very slow inference | stale frame reset, worker slow threshold | no artificially slowed real-camera run |
| Camera temporarily stops | 1800-ms expiry without new frames | no controlled hardware camera-stall injection |
| Repeated Start/Stop | worker cancel/drain/reuse and TTS reuse | all three final camera cycles completed |
| Long operation | not a substitute for hardware | continuous 600.051 s completed |

The user performed a controlled chair/person check and reported “Нет, все норм”
(no issues reported). Device logs include chair/person warnings in all three
directions. This is informal functional feedback, not per-frame ground truth.
An earlier run also reported a bench; its correctness is not established by the
brief feedback. Car and stairs have policy tests but no controlled physical
scene validation in this session.

No trained “Эй, Нави” model is available and no wake-word training was performed.
The existing hey_jarvis_v0.1.onnx asset is not a trained “Эй, Нави” model.

## Offline / Online

Hardware run: OFFLINE_ONLY=true, temporarily disabled Wi-Fi; mobile data was
already off. Wi-Fi was restored after offline camera and synthetic voice tests.
Configured server http://192.168.8.57:8000/health timed out after four seconds
from the workstation. Live Online YOLO, Depth, VLM and real server transitions
cannot be validated in this environment. Host WebSocket handshake success and
rejection tests do not establish model integration.

Source audit: one camera stream per Start, session guards against late replies,
subscription/socket cancellation on fallback, resetScene on transitions and one
persistent offline worker. Duplicate-stream absence across live server switching
remains unverified on hardware.

## Checks completed

- dart format: completed for changed Dart files.
- flutter analyze: no issues.
- flutter test: 73 passed (including the pre-existing trivial widget test).
- flutter build apk --profile: success, normal main entry point.
- APK assets/flutter_assets/NOTICES.Z includes camera_android_camerax license.
- Production Java NV21 packer: 600 cases passed.

Build warning: record_android still applies the Kotlin Gradle plugin; Flutter
warns about a future built-in Kotlin migration requirement. Current builds pass;
dependency migration was not part of this safety validation.

## Measured hardware results

Final camera run completed three Start/Stop cycles: 8.051 s, 8.040 s and
600.051 s measurement windows. First two windows delivered 2.484 and 1.990 new
results/s. The continuous ten-minute window contained 1958 distinct observed
results, or **3.261 new YOLO results/s**, excluding its first result. No YOLO,
TTS engine or camera smoke errors were logged. This is a different duration,
scene and thermal/load condition from v4's 2.736/s, not a paired improvement
claim. One short restart window still fell below 2/s.

| Metric / sample population | p50 | p95 |
| --- | ---: | ---: |
| CameraImage → YOLO return, 1958 results in the ten-minute window | 246.138 ms | 490.825 ms |
| interpreter.invoke, same window | 231.892 ms | 451.714 ms |
| First result → Safety confirmation, 7 initial warning starts | 272.728 ms | 415.748 ms |
| Safety confirmation → native TTS start, same 7 | 782.631 ms | 2162.810 ms |
| First CameraImage of track → native TTS start, same 7 | **1309.796 ms** | **2987.605 ms** |
| Originating confirming evidence age at TTS start, all 38 warning starts | 587.072 ms | 1174.301 ms |

There were 38 warning start callbacks: 7 marked repeat=false and 31 repeats.
The seven initial starts span the whole three-cycle final run, rather than just
the ten-minute window, and include chair/person in all three directions.
repeat=false means the key is absent from the speaker's recent spoken-key map;
it is not a manually annotated physical obstacle onset. One key can become
initial again after map expiry. Quantiles with n=7 are weak tail estimates;
here p95 is the maximum. Separate stage percentiles must not be added together.

Maximum originating confirming evidence age at any start was 1350.096 ms,
below the 1800-ms TTS expiry bound. No expired start was observed. Timer-based
camera-loss expiry and delayed-handoff expiry also pass deterministic host tests.
These checks do not prove perfect detector recall or absence of all stale/native
callback races on all Android engines.

RSS at cycle ends was 349.55 / 356.24 / 383.56 MiB; native heap was approximately
115.32 / 115.68 / 111.35 MiB. Native heap did not grow across those snapshots,
but RSS did increase; three samples and ten minutes do not prove absence of a
memory leak. No thermal isolation or labeled accuracy dataset was used. An
attempt to read UI semantics during inference failed to obtain an idle state;
that short diagnostic may also affect instantaneous performance.

The camera run predates the final manual-description wording/freshness edit;
the Safety/TTS timing and automatic-warning code are the measured versions.
The final main APK was rebuilt and rechecked after the manual-description edit.

## Native voice priority check with synthetic detections

After the camera run, tool/offline_safety_smoke.dart completed on the same phone
with Wi-Fi and mobile data off. This runs real YOLO on a uniform synthetic NV21
frame, but deliberately injects synthetic car/stairs detections into Safety;
it is not evidence that those objects were visually recognized.

- Selected voice: ru-ru-x-ruf-local, network_required=false.
- Description priority 0 cancelled after 182 ms; car priority 2 submitted next.
- Car cancelled after 949 ms when stairs priority 3 became available.
- Stairs start callback received, then speech completed after 2294 ms.
- All 60 speech-enabled inference iterations completed while speech ran;
  delivered rate 13.266/s, median inference 65.276 ms, median Safety CPU work
  0.433 ms, maximum 0.657 ms. This synthetic input rate is not live camera FPS.
- No-speech synthetic series was 11.327/s, median inference 68.861 ms. These
  sequential, non-randomized series include warm-up/load differences; they do
  not demonstrate a speed improvement from enabling TTS.
- COMPLETE offline_voice=true; no native TTS error logged. The short-lived car
  was preempted before a start callback, so no car speech-start latency exists.

Evidence: build/v5_synthetic.log and build/v5_synthetic_build.log. These samples
are excluded from real-camera latency quantiles.

## Restored state and remaining risks

The normal lib/main.dart profile APK is reinstalled, with no OFFLINE_ONLY build
override. Wi-Fi is restored to 1, mobile data remains its original 0 and
stay_on_while_plugged_in is restored to its original 0. Original screen timeout
600000 ms was not changed. Microphone permission was not changed by ADB:
Android rejected both pm revoke (REVOKE_RUNTIME_PERMISSIONS) and AppOps set
(MANAGE_APP_OPS_MODES). Consequently a device button test with denied STT is not
claimed unless separately confirmed by the user. Host STT cancellation and
camera/TTS lifecycle tests pass, but are not a hardware permission-denial test.

Safety latency tails remain material: roughly three seconds from the first
accepted CameraImage for the small measured initial-warning sample. Detection
recall, physical obstacle onset, real car/stairs scenes, hardware camera stalls,
extreme inference delay and live Online/Depth/VLM transitions remain limitations.
No assurance of safe movement, clear path, metric distance or production safety
certification is derived from these tests.

## Reproduction

```powershell
dart format lib/services/safety_service.dart lib/safety_tts_service.dart lib/live_camera_page.dart tool/yolo_camera_smoke.dart test/safety_service_test.dart test/safety_tts_service_test.dart
flutter analyze
flutter test
flutter build apk --profile
flutter run --profile -d d162aebf -t tool/yolo_camera_smoke.dart --dart-define=OFFLINE_ONLY=true --dart-define=CAMERA_SMOKE_SESSIONS=3 --dart-define=CAMERA_SMOKE_LAST_SECONDS=600
flutter run --profile -d d162aebf -t tool/offline_safety_smoke.dart
```

Run device diagnostics sequentially. Restore the normal main APK afterwards.
Quantiles use sorted samples: p50 at index floor(n/2), p95 at
ceil(0.95×(n−1)). Camera throughput excludes the first already-observed result
in each measurement window: (n−1)/window_seconds. Long-window quantiles are
computed on device, not by pooling five-second percentile summaries. Large raw
CAMERA SAMPLES log lines can be truncated by Android logging; CAMERA STATS
contains the complete on-device aggregate for each session.

Local ignored evidence is under build/: v5_tests.log, v5_analyze.log,
v5_build.log, v5_nv21.log, v5_camera.log (initial run, intentionally interrupted
after its first complete 210-second window), v5_camera_final.log,
v5_summary.json and memory snapshots. The initial run predates final timing
anchors and is excluded from the final CameraImage-to-TTS quantiles.

## Changed files

- lib/services/safety_service.dart: track/confirmation timing anchors.
- lib/safety_tts_service.dart: handoff freshness check and TTS start timing.
- lib/live_camera_page.dart: Dart CameraImage-to-result timing, stale manual
  description guard and explicit previous-frame/repeat wording.
- tool/yolo_camera_smoke.dart: configurable durations and timing samples.
- test/safety_service_test.dart: chair motion, timing anchors, slow/pause cases.
- test/safety_tts_service_test.dart: audio handoff regression cases.
- docs/offline_safety_v5_report.md: this report.
