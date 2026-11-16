# Offline YOLO performance and lifecycle

Validated on 2026-11-16 with Flutter 3.47.6 / Dart 3.13.5, CPH2727
(Android 16, arm64), profile builds. Model, backend and dependencies unchanged.

## Causes and fixes

Detect previously awaited encoder setup, a server connection attempt (up to
3 seconds), then model initialization. The existing service already reused its
interpreter; it was not created per frame, and Stop did not normally destroy it.

The original CPU path did not explicitly attach XNNPACK, and the bundled native
runtime did not automatically apply it in this path. Explicit XNNPACK replaces
353/355 nodes with 5 delegated partitions on this model.

The vendored XNNPACK options binding describes an older 24-byte arm64 ABI,
while the pinned LiteRT 1.4.0 uses 56 bytes. The Android wrapper now uses the
matching structure and native defaults. Other platforms retain their previous
wrapper. Header: https://github.com/google-ai-edge/LiteRT/blob/v1.4.0/tflite/delegates/xnnpack/xnnpack_delegate.h

The worker now initializes and warms the model after the first UI frame,
concurrently with camera setup. Detect starts local detection first; online
negotiation runs in the background unless offline-only is selected. Online
remains a fallback if local initialization fails. Stop retains the model.

The default Android CPU configuration is XNNPACK / 4 threads, with ordinary CPU
fallback for Dart-visible delegate setup failures. Native crashes cannot be
caught by Dart try/catch. NNAPI and GPU remain disabled: their driver/accuracy
behavior was not validated. A Dart isolate also does not promise the same native
OS thread required by the GPU delegate.

Actual tensors: Float32 NCHW [1,3,320,320] -> Float32 [1,29,2100]. Shape, type
and byte lengths remain validated. NHWC is supported when reported by a model.
NV21 sampling, rotation, letterboxing, inference and decoding run in the worker.
Its Float32 input buffer is reused; output is read through a native Float32 view.

Only one frame can occupy the worker. Incoming frames are dropped before their
bytes are transferred while it is busy. Stop cancels the caller but keeps the
native slot busy until its real reply. Session identifiers reject results and
encoding jobs from previous runs/modes. The old 20-second timeout killed the
worker; a slow-frame diagnostic now logs without releasing the slot, queuing
work or recreating the model. Actual worker exits still fail pending requests.

## Device measurements

Synthetic NV21 640x480, eight frames/configuration after one warm-up.
The validation run (these are not camera FPS measurements):

| CPU configuration | Median invoke, ms | Median frame total, ms | Warm-up, ms |
| --- | ---: | ---: | ---: |
| Original CPU path, 4 threads | 465.873 | 478.997 | 953.120 |
| XNNPACK, 1 thread | 241.363 | 249.371 | 243.996 |
| XNNPACK, 2 threads | 125.176 | 133.784 | 133.158 |
| XNNPACK, 4 threads | 71.486 | 79.566 | 82.929 |

An earlier run measured CPU 735 ms versus XNNPACK/4 85 ms medians. Thermal,
power and scheduling conditions vary; these are short sequential benchmarks.
Numerical parity on three deterministic non-uniform Float32 inputs: maximum
absolute output error 0.0000062585, maximum score error 0.0000004173, no values
outside abs=0.0001 + rel=0.001 tolerance. This is not labeled dataset validation.

Real camera, ordinary LiveCameraPage with the existing voice/TTS stack,
XNNPACK/4, offline-only, three Start/Stop cycles:

| Session | Button to first result, ms | Stream start API, ms | End-of-session invoke, ms | End-of-session FPS |
| --- | ---: | ---: | ---: | ---: |
| 1 | 1905.26 | 0.75 | 388.895 | 2.14 |
| 2 | 782.94 | 1.21 | 425.724 | 2.14 |
| 3 | 584.95 | 0.81 | 325.040 | 2.74 |

Camera-run preload: model_load_ms=2.79, interpreter_init_ms=258.07,
warmup_inference_ms=448.17, preload_total_ms=810.50. No second initialization
appeared during Stop/Start. Sampled camera invokes were 240–625 ms, including
the first camera frame. Do not present synthetic throughput as camera FPS.
All three cycles completed without YOLO errors. A later optional camera/2-thread
comparison lost the Flutter/device connection and is excluded from results.
No distance/obstacle warning accuracy or navigation safety was tested.

Final verification used the normal lib/main.dart entry point and actual UI
switch/button taps, rather than the smoke harness. The installed profile app
reported Camera ready and Offline YOLO: ready. With offline-only selected,
detect_startup_ms=1057.80 (first result), first-camera inference=556.21 ms.
Subsequent logged frames through frame 60: inference 221.75–500.38 ms and
delivered cadence 1.80–3.71 FPS. No YOLO errors appeared. The UI Stop button
was pressed after recording the results. Metrics are in
build/yolo_diagnostics/final_button_metrics.log.

## Diagnostics and reproduction

Logs use debugPrint, visible in the Flutter console and Android Logcat:

- model_load_ms: async asset loading on the main isolate.
- interpreter_init_ms: worker native setup, allocation and tensor validation.
- warmup_inference_ms, first_inference=true: first native invoke before ready.
- preprocess_ms, input_copy_ms, inference_ms, postprocess_ms.
- worker_total_ms: worker pipeline; frame_total_ms: request to reply, including
  transfer/scheduling. Native camera capture-to-Dart latency is not measured.
- first_camera_frame: first real frame since worker initialization.
- detect_stream_start_ms: button to stream-start API completion.
- detect_startup_ms: button to first accepted result, including camera startup.
- fps: delivered-result cadence, not 1000/native invoke time.

The captured camera logs used detect_first_result_ms for what is now named
detect_startup_ms, and detect_startup_ms for stream-start API duration. The
table above explicitly distinguishes these two measurements.

```powershell
flutter run --profile -d <device> --dart-define=OFFLINE_ONLY=true
flutter run --profile -d <device> -t tool/yolo_benchmark.dart
flutter run --profile -d <device> -t tool/yolo_camera_smoke.dart --dart-define=OFFLINE_ONLY=true
# Optional comparisons: --dart-define=YOLO_THREADS=2
# Or: --dart-define=YOLO_XNNPACK=false
adb logcat -s flutter tflite
```

The benchmark uses synthetic input only, checks native cancellation/reuse and
CPU/XNNPACK numerical parity. The camera smoke tool requires OFFLINE_ONLY and
automatically stops after three sessions. It never uploads frames. Restore the
normal entry point with flutter run --profile.

Validation: dart format; flutter analyze (no issues); separate analysis of the
vendored wrapper; all 24 Flutter tests passed, including worker failures, slow
frames, cancellation, disposal races, tensor layouts, NV21 buffer reuse,
NMS/boxes, and loopback WebSocket success/rejection. Profile APK builds and the
native/camera runs succeeded. Raw logs: ignored build/yolo_diagnostics directory.

FastAPI/WebSocket, TTS/safety alerts, voice assistant, Depth and VLM code paths
are retained. Full live-server/Depth/VLM integration was not exercised. Offline
mode still has no depth estimates or distance-based automatic safety alerts,
as in the starting implementation.
