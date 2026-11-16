import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Bounded aggregates, enabled in debug/profile only.
class PerformanceReport {
  final Map<String, List<double>> _samples = {};
  final Stopwatch _window = Stopwatch();
  Timer? _timer;
  int _camera = 0, _yolo = 0;
  void start() {
    if (kReleaseMode || _timer != null) return;
    _window.start();
    SchedulerBinding.instance.addTimingsCallback(_timings);
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _report());
  }

  void cameraFrame() {
    if (!kReleaseMode) _camera++;
  }

  void yoloResult() {
    if (!kReleaseMode) _yolo++;
  }

  void record(String name, double? value) {
    if (kReleaseMode || value == null || !value.isFinite || value < 0) return;
    final samples = _samples.putIfAbsent(name, () => []);
    if (samples.length == 120) samples.removeAt(0);
    samples.add(value);
  }

  void _timings(List<FrameTiming> timings) {
    for (final frame in timings) {
      record('ui_build_ms', frame.buildDuration.inMicroseconds / 1000);
      record('ui_raster_ms', frame.rasterDuration.inMicroseconds / 1000);
    }
  }

  void _report() {
    final seconds = _window.elapsedMicroseconds / 1000000;
    if (seconds <= 0) return;
    final metrics = <String>[];
    for (final entry in _samples.entries) {
      final sorted = entry.value.toList()..sort();
      metrics.add(
        '${entry.key}[p50=${sorted[sorted.length ~/ 2].toStringAsFixed(2)},p95=${sorted[((sorted.length - 1) * .95).ceil()].toStringAsFixed(2)},n=${sorted.length}]',
      );
    }
    debugPrint(
      'NAV PERF window_s=${seconds.toStringAsFixed(1)} '
      'camera_fps=${(_camera / seconds).toStringAsFixed(2)} '
      'yolo_fps=${(_yolo / seconds).toStringAsFixed(2)} ${metrics.join(" ")}',
    );
    _camera = _yolo = 0;
    _samples.clear();
    _window.reset();
  }

  void dispose() {
    if (kReleaseMode) return;
    _timer?.cancel();
    _timer = null;
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    _window.stop();
  }
}
