import 'dart:math' as math;

/// Visual observation, not a claim of collision risk or a movement instruction.
class SafetyAlert {
  const SafetyAlert({
    required this.key,
    required this.text,
    required this.priority,
    required this.observedAt,
    this.confidence = 0,
  });

  final String key;
  final String text;
  final int priority;
  final DateTime observedAt;
  final double confidence;
}

class _Rule {
  const _Rule(this.name, this.priority, [this.confidence = 0.55]);
  final String name;
  // Speech priority only. Never inferred from apparent box size.
  final int priority;
  final double confidence;
}

class _Box {
  const _Box(this.x1, this.y1, this.x2, this.y2);
  final double x1, y1, x2, y2;
  double get cx => (x1 + x2) / 2;
  double get cy => (y1 + y2) / 2;
  double get area => (x2 - x1) * (y2 - y1);

  double overlap(_Box other) {
    final intersection =
        math.max(0.0, math.min(x2, other.x2) - math.max(x1, other.x1)) *
        math.max(0.0, math.min(y2, other.y2) - math.max(y1, other.y1));
    return intersection / (area + other.area - intersection);
  }

  bool follows(_Box previous) {
    if (overlap(previous) >= 0.35) return true;
    final ratio = area / previous.area;
    // Permit modest movement of narrow poles and small objects, but not a
    // teleporting box or a large unexplained scale change.
    return ratio >= 0.5 &&
        ratio <= 2 &&
        (cx - previous.cx).abs() <= math.min(0.06, (x2 - x1) * 0.4) &&
        (cy - previous.cy).abs() <= math.min(0.06, (y2 - y1) * 0.4);
  }
}

class _Track {
  _Track(this.name, this.box, this.side, this.firstSeen, this.lastSeen);
  final String name;
  _Box box;
  String side;
  final DateTime firstSeen;
  DateTime lastSeen;
  int frames = 1;
}

/// Mobile adaptation of backend/safety_service.py. One shared policy is used
/// for offline and connected detections; server depth/UI/protocol stay intact.
class SafetyService {
  SafetyService({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final List<_Track> _tracks = [];
  int _width = 0, _height = 0;
  static const confirmationFrames = 2;
  static const maxFrameGap = Duration(milliseconds: 1500);
  static const minConfirmationTime = Duration(milliseconds: 120);

  // Road, Building, Traffic sign and Pedestrian crosswalk are scene context,
  // not automatic obstacle warnings. A crosswalk never implies safe crossing.
  static const _rules = <String, _Rule>{
    'stairs': _Rule('лестница', 3, 0.60),
    'manhole': _Rule('люк', 3, 0.60),
    'car': _Rule('автомобиль', 2),
    'bus': _Rule('автобус', 2),
    'truck': _Rule('грузовик', 2),
    'motorcycle': _Rule('мотоцикл', 2),
    'bike': _Rule('велосипед', 2),
    'electrical pole': _Rule('столб', 2),
    'traffic cone': _Rule('дорожный конус', 2),
    'guard rail': _Rule('ограждение', 2),
    'traffic barrel': _Rule('дорожное ограждение', 2),
    'person': _Rule('человек', 1, 0.60),
    'dog': _Rule('собака', 1, 0.60),
    'tree': _Rule('дерево', 1, 0.60),
    'dustbin': _Rule('мусорный бак', 1),
    'bench': _Rule('скамейка', 1),
    'fire hydrant': _Rule('гидрант', 1),
    'plant pot': _Rule('цветочный горшок', 1),
    'electrical box': _Rule('электрический шкаф', 1),
    'chair': _Rule('стул', 1),
    'bicycle rack': _Rule('велосипедная стойка', 1),
  };

  void reset() {
    _tracks.clear();
    _width = _height = 0;
  }

  List<SafetyAlert> evaluate({
    required Iterable<dynamic> detections,
    required int imageWidth,
    required int imageHeight,
    bool allowReliableDepth = false,
    double frameAgeMs = 0,
  }) {
    if (imageWidth <= 0 ||
        imageHeight <= 0 ||
        !frameAgeMs.isFinite ||
        frameAgeMs < 0 ||
        frameAgeMs > 1500) {
      reset();
      return const [];
    }
    if (_width != imageWidth || _height != imageHeight) reset();
    _width = imageWidth;
    _height = imageHeight;
    final now = _clock();
    final previous = List<_Track>.of(_tracks);
    _tracks.clear();
    final alerts = <String, SafetyAlert>{};
    // Bounded work, even if a malformed server response contains huge lists.
    for (final detection in detections.take(80)) {
      if (detection is! Map) continue;
      var name = detection['class_name']?.toString().trim().toLowerCase() ?? '';
      if (name == 'teraffic barrel') name = 'traffic barrel';
      final rule = _rules[name];
      final confidence = detection['confidence'];
      final raw = detection['bbox'];
      if (rule == null ||
          confidence is! num ||
          !confidence.isFinite ||
          confidence < rule.confidence ||
          confidence > 1 ||
          raw is! List ||
          raw.length != 4 ||
          raw.any((v) => v is! num || !v.isFinite)) {
        continue;
      }
      final x1 = (raw[0] as num).toDouble() / imageWidth;
      final y1 = (raw[1] as num).toDouble() / imageHeight;
      final x2 = (raw[2] as num).toDouble() / imageWidth;
      final y2 = (raw[3] as num).toDouble() / imageHeight;
      // Reject invalid/out-of-frame geometry rather than clamping an arbitrary
      // malformed box into an apparently stable obstacle.
      if (x1 < 0 || y1 < 0 || x2 > 1 || y2 > 1 || x2 <= x1 || y2 <= y1) {
        continue;
      }
      final box = _Box(x1, y1, x2, y2);
      _Track? match;
      var bestOverlap = -1.0;
      for (final track in previous) {
        final gap = now.difference(track.lastSeen);
        if (track.name != name ||
            gap.isNegative ||
            gap > maxFrameGap ||
            !box.follows(track.box)) {
          continue;
        }
        final overlap = box.overlap(track.box);
        if (overlap > bestOverlap) {
          match = track;
          bestOverlap = overlap;
        }
      }
      final _Track track;
      if (match != null) {
        previous.remove(match); // one-to-one matching of same-class objects
        track = match;
        track.side = _side(box.cx, track.side);
        track.box = box;
        if (now.isAfter(track.lastSeen)) track.frames++;
        track.lastSeen = now;
      } else {
        track = _Track(name, box, _side(box.cx), now, now);
      }
      _tracks.add(track);
      if (track.frames < confirmationFrames ||
          now.difference(track.firstSeen) < minConfirmationTime) {
        continue;
      }
      final key = '$name:${track.side}';
      final position = switch (track.side) {
        'left' => 'Слева',
        'right' => 'Справа',
        _ => 'Впереди',
      };
      var text = '$position ${rule.name}';
      final distance = allowReliableDepth ? reliableDistance(detection) : null;
      if (distance != null) {
        text +=
            ', примерно ${distance.toStringAsFixed(1).replaceAll('.', ',')} метра';
      }
      final alert = SafetyAlert(
        key: key,
        text: text,
        priority: rule.priority,
        observedAt: now.subtract(
          Duration(microseconds: (frameAgeMs * 1000).round()),
        ),
        confidence: confidence.toDouble(),
      );
      if (!alerts.containsKey(key) || alerts[key]!.confidence < confidence) {
        alerts[key] = alert;
      }
    }
    final result = alerts.values.toList()
      ..sort((a, b) {
        final priority = b.priority.compareTo(a.priority);
        if (priority != 0) return priority;
        final center =
            (b.key.endsWith(':center') ? 1 : 0) -
            (a.key.endsWith(':center') ? 1 : 0);
        return center != 0 ? center : b.confidence.compareTo(a.confidence);
      });
    return result.take(3).toList(growable: false);
  }

  static String _side(double center, [String? previous]) {
    // Hysteresis stops a box near a third boundary alternating left/center.
    if (previous == 'left' && center < 0.38) return 'left';
    if (previous == 'right' && center > 0.62) return 'right';
    if (previous == 'center' && center >= 0.28 && center <= 0.72) {
      return 'center';
    }
    return center < 0.33
        ? 'left'
        : center > 0.67
        ? 'right'
        : 'center';
  }

  /// Current server distance_m alone is experimental and is NOT sufficient.
  /// A future metric-depth provider must supply all this quality metadata.
  static double? reliableDistance(Map<dynamic, dynamic> detection) {
    final distance = detection['distance_m'];
    final confidence = detection['distance_confidence'];
    final age = detection['distance_age_ms'];
    if (detection['distance_reliable'] != true ||
        !const [
          'sensor_metric',
          'calibrated_metric',
        ].contains(detection['distance_source']) ||
        distance is! num ||
        !distance.isFinite ||
        distance <= 0 ||
        distance > 50 ||
        confidence is! num ||
        !confidence.isFinite ||
        confidence < 0.8 ||
        confidence > 1 ||
        age is! num ||
        !age.isFinite ||
        age < 0 ||
        age > 1000) {
      return null;
    }
    return distance.toDouble();
  }
}
