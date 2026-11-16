# Offline visual warnings and smart TTS

Implemented and tested on 2026-11-16. The optimized LocalYoloService,
preprocessor, postprocessor, model, delegate configuration and dependencies
were not changed for this feature.

## Integration

`lib/services/safety_service.dart` is the mobile adaptation of the existing
Python `backend/safety_service.py`, required because the Python server is not
available offline. There is one mobile evaluator owned by the existing
`SafetyTtsService`, and one FlutterTts engine. LiveCameraPage feeds accepted
offline and connected detections into the same evaluator/speaker. The backend
protocol and its safety/depth implementation remain available unchanged.

Automatic speech uses locally validated observations rather than forwarding
arbitrary server text. Existing Depth/VLM, boxes, voice-command replies,
connection negotiation and Start/Stop paths remain in place.

## Observation policy

- Confidence >= 0.55; stairs, manholes, people, dogs and trees require >= 0.60.
- Two consecutive matching observations, at least 120 ms apart. Gaps over
  1500 ms, missing detections, stale results and mode/geometry changes reset
  confirmation. Multiple same-class detections in one frame cannot confirm
  each other. Matching is one-to-one, based on IoU or bounded relative movement.
- The box center determines left/center/right, with boundary hysteresis.
  Positions refer to the camera view, not a verified navigable route.
- Stairs/manholes: speech priority 3. Vehicles, bicycle, poles, cones and
  barriers: priority 2. People and other supported physical obstacles:
  priority 1. These are announcement priorities, not collision predictions.
- Road, Building, Traffic sign and Pedestrian crosswalk are scene context,
  not automatic obstacle warnings. The trained `Teraffic Barrel` spelling is
  normalized to `traffic barrel`.
- No distance or imminent-danger inference from box size, and no claims that
  a route is clear or that crossing is safe. Empty detections produce silence.
- Invalid/non-finite confidence and geometry are rejected. Results older than
  1500 ms are rejected for speech. Work is bounded to 80 detections and three
  distinct class/direction announcements per frame.

Offline always ignores distance metadata. Connected mode may announce an
approximate distance only when Depth is enabled and every per-object field
passes the explicit metric-quality contract:

| Field | Required value |
| --- | --- |
| distance_reliable | true |
| distance_source | sensor_metric or calibrated_metric |
| distance_confidence | finite, 0.8–1.0 |
| distance_age_ms | finite, 0–1000 |
| distance_m | finite, >0 and <=50 |

The current server provides experimental distance_m without these reliability
fields. It therefore continues displaying Depth values but automatic warnings
remain visual-only. Reliability metadata must come from a validated provider;
setting flags on experimental monocular estimates would not validate them.

## Speaker lifecycle

Only one serialized runner calls speak. A warning of priority >=2 can interrupt
a normal description; a higher-priority warning can interrupt a lower warning.
The native stop acknowledgement precedes the next speak. Equal priorities do
not repeatedly interrupt each other. A missing platform speak-completion event
after stop cannot keep the runner locked indefinitely.

There is one active utterance, up to three latest confirmed scene observations,
and at most one pending manual reply. New replies replace queued older replies.
Warnings expire 1800 ms after their supporting frame (including measured frame
processing age); queued manual replies expire after four seconds. No old scene
description is replayed after interruption. A single missed detection does not
chop an active short phrase immediately, but that phrase still expires when
its last supporting evidence ages out. Frame stalls therefore expire speech
even if no new frames arrive.

Per class/direction cooldown is 12/20/30 seconds for priorities 3/2/1, measured
from successful completion, or from the attempt if interrupted/failed. Cooldown
survives mode changes and Stop/Start. Confirmation/scene evidence does not.
Muting stops automatic warnings but still permits explicit command replies.
Backgrounding clears speech and disables automatic warnings until resume.

Speech watchdogs are 8 seconds for warnings and 30 seconds for manual replies.
If native stop cannot be confirmed within two seconds, further audio is blocked
instead of risking overlap; the UI reports unavailable voice warnings. Restart
the page/app after correcting a failed speech engine.

Android initialization selects an installed Russian voice with network_required
false, excluding notInstalled voices. There is no fallback to a network voice.
If none exists, the UI asks the user to check/install an offline Russian voice
through Android's speech synthesis settings; inference continues. The manifest
includes Android's TTS service visibility query. This uses the existing
flutter_tts API: https://pub.dev/packages/flutter_tts

## Verification and measured limits

- dart format: clean.
- flutter analyze: no issues.
- flutter test: all 52 tests pass, including 28 new safety/TTS tests.
- Unit coverage: confidence, all directions, hysteresis, temporal/one-to-one
  matching, invalid input, priorities, distance gating, cooldown, active and
  queued deduplication, preemption/stop ordering, expiry without new frames,
  mode reset, mute, missing offline voice, hung speak future, failed native
  stop, and detection-to-speech integration.
- Android CPH2727, Android 16, profile build: selected
  ru-ru-x-ruf-local with network_required=false. Controlled synthetic run
  used actual TFLite and Android TTS concurrently, without camera/network:
  the description was interrupted after 293 ms, the automobile announcement
  was subsequently replaced by stairs, and stairs completed in 1891 ms.
  Native playback-start callbacks were observed.
- For 40 test boxes per frame, safety evaluation median 0.486 ms, maximum
  1.087 ms. Sequential 60-frame phases measured median native inference
  157.553 ms without speech and 95.533 ms with safety/speech (4.95 vs 7.31
  delivered FPS). These uncontrolled sequential measurements do not imply
  that speech improves inference; they establish a running concurrent path.
- The real camera smoke test completed three Start/Stop cycles and generated
  a confirmed dustbin warning from real detections. That build still stopped
  speech immediately on a missed frame; the final version adds the bounded
  single-miss grace described above, covered by unit tests.
- Real-camera native inference was variable and slower than the earlier YOLO
  optimization session: end-of-session samples 1245–1888 ms, 0.52–0.75 FPS.
  Thermal status was 2 with shell_skin=41 C. A subsequent same-process toggle
  comparison measured 775 ms / 1.18 FPS with warnings disabled and
  387–551 ms / 1.63–2.28 FPS with warnings enabled. Camera safety evaluation
  samples were 0.033–0.082 ms. These sparse samples show no added safety
  slowdown, but do not establish sustained camera FPS or isolate the cause
  of device load/thermal variability. No inference settings were changed.
- Normal-entry-point verification with actual UI taps: first result 1105.74 ms,
  sampled subsequent native invokes 322–910 ms / 1.03–2.39 FPS. Safety samples
  0.033–0.112 ms, with one 3.786 ms cold/scheduling outlier. This slower camera
  run is reported separately from synthetic throughput. Stop was verified.

The real-camera and synthetic diagnostic entry points are intentionally
separate. The synthetic tool explicitly labels its detections as test data;
they are never injected into production detections:

```powershell
flutter run --profile -d <device> -t tool/offline_safety_smoke.dart
flutter run --profile -d <device> -t tool/yolo_camera_smoke.dart --dart-define=OFFLINE_ONLY=true
flutter run --profile -d <device>
adb logcat -s flutter tflite
```

Logs are in the ignored build/yolo_diagnostics directory:
offline_safety_smoke.log, offline_safety_camera.log, safety_camera_ab.log,
safety_flutter_tests.log and final_safety_app.log. SAFETY PERF records safety_ms;
TTS PERF records speech duration/cancellation separately from YOLO timing.
The normal UI-tap run is in final_safety_button_metrics.log.

No live-server Depth/VLM end-to-end test or labeled obstacle/safety-accuracy
validation was performed. Stable detections can still be wrong; these are
conservative visual observations, not verified route or collision guarantees.
