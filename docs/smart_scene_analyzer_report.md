# Smart Scene Analyzer вЂ” 2026-11-18

Implementation extends the existing offline/online SafetyService and single
Flutter TTS speaker. Existing working-tree changes were retained.

## Behavior

- Existing validation, two observations, 120 ms minimum confirmation, bounded
  80 detections and 1500 ms frame freshness remain in SafetyService.
- Tracker IDs are monotonic within the service lifetime. One partial-result
  dropout preserves confirmed IDs; an empty result clears tracking evidence.
- SmartSceneAnalyzer groups confirmed objects by class, retains individual risk
  evaluations, excludes old evidence and deduplicates tracker IDs. Near-identical
  boxes (IoU > .85) are rejected before tracking to avoid inflated counts.
- Default zones are 0вЂ“.35, .35вЂ“.65, .65вЂ“1, configurable via analyzer injection;
  spatial hysteresis is .03. Same-zone groups retain direction; mixed-zone groups
  use a general description. Five people form a crowd phrase. Other counts are
  expressed as several objects, without enumerating bounding boxes.
- A partial missed result is tolerated for one result only, retaining the
  originating evidence timestamp. Established noncritical group wording changes
  after two results, and never survives beyond its supporting evidence TTL.
- Deterministic rank = existing policy priority * 100 + center bonus 20 +
  confidence * 10 + min(observations, 10). Priority always dominates the score.
  Existing stairs/manhole priority 3 policy is preserved; this is speech priority,
  not a physical collision prediction. Cars remain priority 2. No box-size depth.
- Each critical track bypasses grouping and has its own cooldown key. Ordinary
  class cooldowns survive count/direction wording changes. Cooldowns remain
  12/20/30 seconds. All scene groups remain available; TTS bounds waiting alerts
  to three and keeps one active utterance with native-stop serialization.
- TTS evidence TTL is tightened from 1800 to 1500 ms. Existing checks immediately
  before native speak and cancellation after asynchronous audio handoff remain.
- The existing describe voice command uses up to three confirmed fresh scene
  groups and explicitly describes the last processed frame. Empty or stale
  scenes make no free-path claim.

## Automated validation

`flutter test`: 84 tests passed. `flutter analyze`: no issues.

New tests cover one/two/five/nine people, mixed directions and a center person,
partial disappearance, stale/empty/reset results, duplicate boxes, configurable
zone hysteresis, mixed-class ordering, independent critical track keys, class
cooldowns across group/direction changes and new critical hazards during another
track cooldown. Existing TTS handoff, native stop, expiry and offline voice tests
continue to pass.

## Device and build measurements

Release APK built successfully with `flutter build apk --release
--dart-define=OFFLINE_ONLY=true` (130,775,062 bytes). SHA256:
`BDEAF51FB7E8B8E81BF151554F2EF834628069DD761A80F1B714F900619F8973`.
Artifact: `build/app/outputs/flutter-apk/app-release.apk` (normal main entrypoint).
Gradle emitted existing flutter_tts/record_android Kotlin migration warnings.
An initial overlapping build lost a Gradle daemon; the final build succeeded.

Host stress measurement (`dart run tool/smart_scene_benchmark.dart`): 80
simultaneous objects (50 people, 20 cars, 10 stairs), 1,000 warmup results and
10,000 measured results. Combined SafetyService + analyzer CPU time p50 0.364 ms,
p95 0.468 ms, max 1.250 ms. Output retained 12 candidates: two ordinary groups
and ten independent critical tracks. This is a host JIT measurement, not Android
FPS or a paired pre/post benchmark.

Device: CPH2727 Android 16 ARM64, offline profile camera smoke entrypoint,
three Start/Stop cycles, with the last measurement configured for 600 seconds.
An earlier run lost camera focus near screen timeout and is excluded from the
continuous-work claim. The repeated run temporarily increased screen-off timeout
from 600,000 to 1,800,000 ms; the original value is restored afterwards.
Final camera results are appended below.

## Limits

Synthetic tests cover crowded scenes and critical objects; the unattended camera
run does not provide manually annotated recall, hazard detection accuracy or an
end-to-end spoken-command acceptance test. It must not be presented as validating
safe navigation. Near-identical real objects may be merged by duplicate rejection;
tracking may assign new IDs after sustained occlusion. A critical track that truly
loses tracking may therefore warn again.

No Whisper, VLM, Depth Anything or OpenWakeWord integration is added by this task.
The existing command input remains. Whisper Offline Integration is a separate
next stage, requiring its own integration scope and model/device validation.

## Final continuous device run

Three Start/Stop sessions completed with `CAMERA SMOKE COMPLETE`, zero smoke
errors. Final window: **600.041 seconds**, 2556 distinct sampled results,
2555 new results after the initial sample: **4.258 YOLO results/s**.
The screen remained awake during this run. Three native TTS start callbacks
were recorded: car:center, person:center, person:left (two initial and one repeat).
These are engine callbacks, not acoustic onset or annotated detector accuracy.
With n=3, p95 below is simply the largest sample and is a weak tail estimate.

| Speech stage, all 3 observed starts | p50 | p95 |
| --- | ---: | ---: |
| First result to confirmation | 242.043 ms | 434.131 ms |
| Confirmation to TTS start | 843.986 ms | 1069.563 ms |
| First CameraImage to TTS start | 1451.770 ms | 1567.330 ms |
| Originating confirming evidence age at TTS start | 1223.972 ms | 1237.975 ms |

All observed originating evidence ages were below the 1500-ms TTS bound.
The historical v5 camera-to-TTS p50/p95 were 1309.796/2987.605 ms (7 initial
starts); these populations differ, so the speech samples are not a paired
before/after comparison. Stage percentiles must not be added together.

| Metric | Before: historical v5 | After: this 600-second window |
| --- | ---: | ---: |
| New YOLO results/s | 3.261 | 4.258 |
| CameraImage callback to YOLO result p50 | 246.138 ms | 188.080 ms |
| CameraImage callback to YOLO result p95 | 490.825 ms | 265.240 ms |
| Interpreter invocation p50 | 231.892 ms | 175.745 ms |
| Interpreter invocation p95 | 451.714 ms | 253.691 ms |

The before and after scenes, duration populations and thermal/load conditions
are not controlled or paired. These values do not establish an optimization
speedup attributable to grouping. There is no observed throughput regression in
this particular run. Grouped multi-object behavior and critical preemption are
covered by automated tests; physical annotated crowded/hazard scenes remain to
be checked manually.

Sampled SafetyService + analyzer execution across the three sessions (logged
periodically, not every evaluation): n=90, p50=0.057 ms,
p95=0.125 ms, max=0.375 ms. This is CPU execution time, excluding
waiting for confirmation and speech. Native camera packing average for the long
window: 3.871 ms. End-of-window RSS: 340.9 MiB.

Compact machine-readable measurements: `smart_scene_validation.json`.
Raw local logs: `scene_phone_device.log`, `scene_all_tests_final2.log`,
`scene_analyze_complete2.log`, `scene_build_final.log`, `scene_benchmark.log`.
The full phone log is local/ignored rather than embedded in source control.

After measurement, the original 600,000-ms screen timeout was restored and
the normal release APK was installed successfully with app data retained.
