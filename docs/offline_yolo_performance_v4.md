# Offline YOLO performance v4 — 2026-11-16

The adopted change keeps the original FP32 model, 320×320 input, all 25 ROD
classes, high-resolution preview/analysis, XNNPACK/4 threads, preprocessing
sampling and bounding-box transforms. TTS, SafetyService, Voice Assistant and
openWakeWord source were not changed in v4. No new runtime library was installed;
the existing CameraX 0.7.6 dependency is overridden by a licensed local copy.

Model SHA256: `81e210968f0706d1fc1d78ab43ab4cc1e491a4a11eb7b691f3c1e7a4768f6386`.

## Findings and fixes

The upstream NV21 path calls `imageProxy.getPlanes()` first. Creating the three
Pigeon PlaneProxy objects serializes their byte buffers to Dart, even though the
NV21 branch then asks native code to read those same planes and pack NV21.
The native wrapper also allocates/copies a second packed array before returning.
App-side busy checks happen after these large transfers have already occurred.

The local plugin now:

1. Checks offline worker admission before retrieving any plane bytes. Rejected
   frames close immediately; no retained CameraImage or FIFO is introduced.
2. Passes ImageProxy directly to the native NV21 packer, avoiding three unused
   plane-buffer deliveries. Returns its newly allocated packed array directly,
   avoiding the second packed-array copy. Codec/Flutter and transferable copies
   still exist; this is not a zero-copy pipeline.
3. Allocates exactly width×height×3/2 bytes for packed output, including padded
   Y rows. Duplicates source ByteBuffers to preserve their positions. Output is
   newly owned for each admitted frame, never overwritten during serialization.
4. Closes every accepted/rejected image in finally, including conversion and
   delivery errors. Avoids adding events to a closed stream controller.
5. Supports an opt-in ImageAnalysis resolution separately from Preview and
   ImageCapture; defaults retain the original preset. No model resolution change.

The worker already reuses one Float32 input buffer and interpreter. Output is a
native Float32 view, not a copied nested tensor. These were retained: their
measured costs do not justify unsafe pointer caching or shared mutable buffers.
TransferableTypedData still performs one bounded ownership copy per accepted
frame. Stop preserves the native busy slot until its actual reply, including
when a previous session's Dart caller has been cancelled.

## Comparable full-camera runs

CPH2727, Android 16 ARM64, profile mode, the same model, high camera preset,
1280×720 single-plane NV21, offline-only, existing voice stack enabled. Baseline
uses the original hosted CameraX 0.7.6 and pre-v4 camera page. Optimized uses the
local plugin and admission hook. Benchmarks ran sequentially, never concurrently.

Each condition has three Start/Stop cycles and an approximately eight-second
measurement window after its first accepted result: 24.181 / 24.122 seconds total.
The first observed result in each window is excluded from the FPS numerator;
28 / 66 subsequent delivered results give the average below. Inference quantiles
use all 31 / 69 distinct result samples, including each first result. This is an
application result rate, not 1000/invoke_ms. Sampling polls timestamps every 10 ms.

| Metric | Before | After |
| --- | ---: | ---: |
| Camera analyzer callbacks/s, logged active five-second windows | 7.75–14.02 | 22.07–24.00 |
| Delivered YOLO results/s, combined windows | 1.158 | 2.736 |
| Inference p50 | 563.332 ms | 242.924 ms |
| Inference p95 | 1408.397 ms | 684.536 ms |
| NV21 preprocessing p50 / p95 | 10.962 / 30.863 ms | 9.708 / 25.402 ms |
| Result roundtrip p50 / p95 | 617.995 / 1687.135 ms | 250.289 / 709.716 ms |
| Postprocessing p50 / p95 | 1.788 / 7.986 ms | 1.397 / 2.519 ms |
| Detect startup, cycles 1 / 2 / 3 | 1922 / 794 / 1331 ms | 4896 / 663 / 384 ms |
| Process RSS, cycle-end samples | 386.69–399.44 MiB | 351.31–356.08 MiB |
| Process PSS, cycle-end samples | 281.43–288.07 MiB | 233.86–238.75 MiB |
| CPU time / wall time, process average; 100% = one core | 320.83% | 292.68% |
| Java allocated bytes / wall time, whole process | 171.66 MB/s | 12.84 MB/s |
| Java GC count, combined measurement windows | 170 | 41 |
| Reported ART cumulative GC time delta | 17572 ms | 3358 ms |

Camera FPS here means CameraX analyzer callbacks observed in Dart. After the
change they are counted before byte conversion/admission; before, the original
callback count was after conversion. Neither is a measurement of preview render
FPS or sensor exposure rate. The lower delivery overhead lets the analyzer turn
over faster. Partial Start/Stop windows can affect the range; YOLO's combined
window rate is the better throughput comparison.

The first optimized Start was slower, not faster: 4.90 seconds. Warm restarts
improved, but the data does not establish a cold-start improvement. Individual
optimized cycles averaged about 1.87 / 2.74 / 3.61 new results/s, so even the
2 FPS target is not achieved in every short window. An earlier optimized high
run ended its three cycles at 4.46 / 2.04 / 4.62 results/s; do not substitute
those instantaneous values for the combined-window result above.

Supplementary earlier running-process meminfo snapshots, separate from this
paired result series: app SwapPSS 886 KiB before / 214 KiB after. Global swap
snapshots were approximately 2.36 / 2.54 GiB; global swap includes other apps and
must not be attributed to this model. The device was not rebooted and unrelated
apps were not terminated. Background load and thermal state varied: captured
skin readings were 39–41°C, thermal LIGHT–MODERATE. Thus the tests demonstrate an
observed improvement, not a thermally controlled causal estimate for each fix.

The optimized native heap samples were 111.11 / 105.50 / 108.96 MiB; RSS varied by
less than 5 MiB across these three cycle-end samples. No sustained native-heap
growth is evident in this short run, but it is not a long-duration leak test.

## Stage separation

A final independent instrumented high-resolution cycle measured native packing
at **11.95 ms average** over 29 calls. This is measured around the actual Java
packer, separately from Pigeon request/response overhead.

One steady five-second report window in that final run:

| Stage | p50 | p95 |
| --- | ---: | ---: |
| Native packing + channel conversion roundtrip | 10.79 ms | 20.31 ms |
| NV21 ownership copy to TransferableTypedData | 0.48 ms | 0.82 ms |
| Worker materialize/view | 0.01 ms | 0.06 ms |
| NV21 → RGB/resize/letterbox | 6.55 ms | 18.73 ms |
| Input tensor copy | 0.50 ms | 1.34 ms |
| interpreter.invoke | 196.41 ms | 310.23 ms |
| Output tensor view, not a copy | 0.01 ms | 0.21 ms |
| YOLO decode/NMS | 1.54 ms | 3.84 ms |
| Remaining isolate/result scheduling overhead | 1.03 ms | 15.81 ms |

The native packing average and roundtrip quantiles come from different window
populations; do not subtract their values. Native sensor capture-to-analyzer
delay and individual codec allocation counts are not exposed by these timers.
ART allocated-byte deltas cover the whole Java process; they are not counts of
Dart/native allocations. The source audit identifies eliminated large arrays;
there is no claim that every allocation in the framework was measured.

## Camera resolution experiment and accuracy boundary

With YOLO_ANALYSIS_WIDTH=640 / HEIGHT=360, the actual analysis frames were
640×360 NV21 (345600 bytes) while Preview stayed 1280×720. The same 16:9 aspect
ratio preserves the existing orientation/box mapping assumptions. This is why
the test preferred 640×360 rather than silently pairing 4:3 analysis with 16:9
preview. CameraX can fall back: inspect actual dimensions, never assume the
requested size. Android supports separate use-case resolution selectors; the
public Flutter CameraController preset alone does not expose that separation.

The three experimental cycles ended at 1.09 / 3.77 / 3.39 results/s, with startup
2536 / 439 / 315 ms. Smaller analysis did not show a consistent advantage. No
labeled small-obstacle dataset/reference scene was available to establish recall
at that resolution. Therefore reduced analysis is **opt-in only**, and the
adopted default retains both high analysis and preview quality.

The default packer passed exact expected-byte comparisons over 600 combinations
of geometry, padding and UV pixel stride, including independent output ownership
and unchanged source positions. Existing tests cover rotation, letterboxing,
tensor layouts, NMS and boxes. The model, class mapping, thresholds and sampling
are unchanged, but these checks are not labeled-dataset accuracy validation.
Hardware runs had no confirmed obstacle warnings, so no real-world warning
accuracy or obstacle-to-speech latency claim is made. Online/Depth/VLM interfaces
were retained; their live-server integration was not exercised.

## CPU and delegate experiments

Same synthetic 640×480 NV21 input, eight frames after warm-up, sequential workers:

| Configuration | Invoke p50 | Invoke p95 |
| --- | ---: | ---: |
| CPU, 1 thread | 451.158 ms | 591.715 ms |
| CPU, 2 threads | 204.934 ms | 280.435 ms |
| CPU, 4 threads | 234.271 ms | 268.725 ms |
| XNNPACK, 1 thread | 233.095 ms | 260.655 ms |
| XNNPACK, 2 threads | 99.091 ms | 106.778 ms |
| XNNPACK, 4 threads | 63.296 ms | 67.760 ms |

Three deterministic nonuniform Float32 inputs passed CPU/XNNPACK comparison:
no elements outside abs=0.0001 + rel=0.001 tolerance; maximum absolute error
0.0000062585. This is raw tensor parity, not obstacle accuracy.

Separate synchronous delegate probes use the same seeded nonuniform input,
eight measured invokes, one delegate at a time:

| Requested backend | Invoke p50 | Invoke p95 | Outside tolerance |
| --- | ---: | ---: | ---: |
| NNAPI option | 261.759 ms | 305.662 ms | 0 |
| GPU, OpenCL; one GPU kernel reported | 101.759 ms | 119.265 ms | 0 |
| XNNPACK/4 | 169.434 ms | 369.085 ms | 0 |

NNAPI execution succeeded, but logs do not establish hardware partition coverage;
do not call it proven NPU acceleration. Probe differences include thermal and
background-load variation. GPU initialization/invoke/destruction ran in one
synchronous isolate callback. Production is an event-driven worker, for which
GPU native-thread affinity across callbacks has not been validated. One passing
input does not justify changing its production delegate. Production remains the
validated XNNPACK CPU path with its existing setup-error CPU fallback. Probes do
not change production selection and were followed by normal app restoration.

The original model was not replaced with FP16/INT8: the adopted fix meets the
average 2 FPS target, and there is no calibration/labeled validation to justify
quantization accuracy changes. Five sustained FPS remains unproven.

## Files changed in v4

- `lib/live_camera_page.dart`: offline admission before plane conversion, camera
  profiling hooks/cleanup, opt-in analysis dimensions, additional worker stages.
- `lib/services/local_yolo_service.dart`: separate ownership-copy/materialize/
  output-view timing; no inference, buffer layout or model change. Detailed stage
  logs are restricted to debug/profile.
- `android/app/src/main/kotlin/com/example/camera/MainActivity.kt`: an on-demand
  diagnostic snapshot channel for process CPU, ART allocation/GC, native heap,
  PSS and optional native packing counters. No camera or audio lifecycle changes.
- `pubspec.yaml`, `pubspec.lock`: local override of the same CameraX version and
  explicit dependency for its admission hook. No new runtime dependency versions.
- `third_party/camera_android_camerax/`: licensed 0.7.6 source. Owned changes are
  `analysis_frame_processor.dart`, `android_camera_camerax.dart`, Pigeon schema and
  matching Dart/Kotlin generated bindings, `ImageProxyUtils.java`, its proxy API,
  and native API/packing tests. `LOCAL_CHANGES.md` records the patch.
- `tool/yolo_benchmark.dart`: CPU 1/2/4 comparison and p95.
- `tool/yolo_delegate_probe.dart`: isolated opt-in NNAPI/GPU/XNNPACK parity probe.
- `tool/yolo_camera_smoke.dart`: per-cycle quantiles, raw timing samples, CPU,
  allocation/GC and memory snapshots; default remains three Start/Stop cycles.
- `tool/NativeNv21PackingCheck.java`, `tool/check_nv21_packing.py`: dependency-free
  test of the actual production Java packer against known expected pixel bytes.
- `test/camera_frame_pipeline_test.dart`: admission before copying, direct NV21
  delivery, geometry, and image closure on rejection/failure/disposal.
- This report.

## Verification and reproduction

- dart format completed; flutter analyze and separate local-plugin lib analysis
  report no issues. All **68 Flutter tests** passed.
- Actual production Java packer: **600 cases passed** via javac/java 17 with
  minimal compile-time Android interface stubs; no downloaded test framework.
- Upstream Gradle native test task compiled the tests but did not finish; it was
  cancelled. No successful Gradle JUnit result is claimed.
- Profile builds installed and ran on the device. Both main comparison series
  completed all three cycles without YOLO errors or worker reload on restart.
- Screen stay-awake was temporary; restore original setting 0 after testing.

```powershell
flutter test
flutter run --profile -d d162aebf -t tool/yolo_camera_smoke.dart --dart-define=OFFLINE_ONLY=true
flutter run --profile -d d162aebf -t tool/yolo_benchmark.dart
flutter run --profile -d d162aebf -t tool/yolo_delegate_probe.dart --dart-define=PROBE_DELEGATE=gpu
python tool/check_nv21_packing.py --java-home 'C:/Program Files/Eclipse Adoptium/jdk-17.0.21.9-hotspot'
# Restore the normal app without benchmark/offline-only overrides:
flutter run --profile -d d162aebf -t lib/main.dart
```

Do not launch another device benchmark before the previous COMPLETE marker.
All raw evidence is local/ignored under `build/yolo_diagnostics/v4/`: synthetic,
baseline/high/640 camera logs, paired `camera_*_stats.log`, `comparison.json`,
NNAPI/GPU/XNNPACK probes, meminfo/top/thermal snapshots, final stage log,
`tests_final.log`, native-test attempt and `main_final.log`.

Sources: installed CameraX 0.7.6 source, [CameraX ImageAnalysis.Builder](https://developer.android.com/reference/androidx/camera/core/ImageAnalysis.Builder),
[ImageAnalysis backpressure](https://developer.android.com/reference/androidx/camera/core/ImageAnalysis),
[LiteRT GPU thread requirement](https://developers.google.cn/edge/litert/android/gpu).
