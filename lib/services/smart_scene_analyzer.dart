import 'safety_service.dart';

/// Confirmed, individually evaluated tracker evidence; no raw YOLO input.
class SceneObject {
  const SceneObject({
    required this.trackId,
    required this.className,
    required this.side,
    required this.stability,
    required this.alert,
  });
  final int trackId, stability;
  final String className, side;
  final SafetyAlert alert;
  double get score =>
      alert.priority * 100 +
      (side == 'center' ? 20 : 0) +
      alert.confidence * 10 +
      stability.clamp(0, 10);
}

class SmartSceneAnalyzer {
  SmartSceneAnalyzer({
    this.leftBoundary = .35,
    this.rightBoundary = .65,
    this.hysteresis = .03,
  }) : assert(leftBoundary > 0 && leftBoundary < rightBoundary),
       assert(rightBoundary < 1),
       assert(hysteresis >= 0 && hysteresis < .15);
  final double leftBoundary, rightBoundary, hysteresis;
  final Map<int, SceneObject> _recent = {};
  final Map<String, DateTime> _wordingEvidence = {};
  final Map<String, (String, String, int)> _wording = {};

  String side(double x, [String? previous]) {
    if (previous == 'left' && x < leftBoundary + hysteresis) return 'left';
    if (previous == 'right' && x > rightBoundary - hysteresis) return 'right';
    if (previous == 'center' &&
        x >= leftBoundary - hysteresis &&
        x <= rightBoundary + hysteresis) {
      return 'center';
    }
    return x < leftBoundary
        ? 'left'
        : x > rightBoundary
        ? 'right'
        : 'center';
  }

  void reset() {
    _recent.clear();
    _wording.clear();
    _wordingEvidence.clear();
  }

  List<SafetyAlert> analyze(List<SceneObject> input, DateTime now) {
    bool fresh(SceneObject o) =>
        !now.isBefore(o.alert.observedAt) &&
        now.difference(o.alert.observedAt) <= SafetyService.maxFrameGap;
    final current = {for (final o in input.where(fresh)) o.trackId: o};
    // Tolerate one missed result in a partial scene, with original evidence age.
    final visible = <int, SceneObject>{
      if (current.isNotEmpty)
        for (final e in _recent.entries)
          if (fresh(e.value)) e.key: e.value,
      ...current,
    };
    _recent
      ..clear()
      ..addAll(current);
    final groups = <String, List<SceneObject>>{};
    for (final o in visible.values) {
      final key = o.alert.priority == 3
          ? '${o.className}:track:${o.trackId}'
          : o.className;
      groups.putIfAbsent(key, () => []).add(o);
    }
    _wording.removeWhere((key, _) => !groups.containsKey(key));
    _wordingEvidence.removeWhere((key, _) => !groups.containsKey(key));
    final result = <SafetyAlert>[];
    for (final entry in groups.entries) {
      final members = entry.value..sort((a, b) => b.score.compareTo(a.score));
      final best = members.first;
      final a = best.alert;
      var text = a.text;
      if (members.length > 1) {
        final noun = _plurals[best.className];
        final sides = members.map((o) => o.side).toSet();
        final position = sides.length == 1
            ? switch (sides.single) {
                'left' => 'Слева',
                'right' => 'Справа',
                _ => 'Впереди',
              }
            : 'Впереди';
        text = best.className == 'person' && members.length >= 5
            ? '$position группа людей'
            : '$position несколько ${noun ?? 'объектов класса ${best.className}'}';
        if (best.className == 'person' &&
            members.length < 5 &&
            sides.length > 1 &&
            members.where((o) => o.side == 'center').length == 1) {
          text += ', один по центру';
        }
      }
      // Require two distinct results before changing established group wording.
      // Never delay or reuse critical wording, or metric-distance updates.
      if (a.priority < 3 && !text.contains('метра')) {
        final old = _wording[entry.key];
        if (old == null ||
            old.$1 == text ||
            now.difference(_wordingEvidence[entry.key]!) >
                SafetyService.maxFrameGap) {
          _wording[entry.key] = (text, text, 0);
          _wordingEvidence[entry.key] = members
              .map((o) => o.alert.observedAt)
              .reduce((x, y) => x.isBefore(y) ? x : y);
        } else {
          final count = old.$2 == text ? old.$3 + 1 : 1;
          _wording[entry.key] = count >= 2
              ? (text, text, 0)
              : (old.$1, text, count);
          text = _wording[entry.key]!.$1;
          if (count >= 2) _wordingEvidence[entry.key] = a.observedAt;
        }
      }
      result.add(
        SafetyAlert(
          key: a.priority == 3
              ? entry.key
              : members.length > 1
              ? '${entry.key}:group'
              : a.key,
          text: text,
          priority: a.priority,
          observedAt: members
              .map((o) => o.alert.observedAt)
              .reduce((x, y) => x.isBefore(y) ? x : y),
          confidence: a.confidence,
          riskScore: best.score,
          firstResultAt: a.firstResultAt,
          firstCameraAt: a.firstCameraAt,
          confirmedAt: a.confirmedAt,
        ),
      );
    }
    result.sort((a, b) {
      final score = b.riskScore.compareTo(a.riskScore);
      return score != 0 ? score : a.key.compareTo(b.key);
    });
    return List.unmodifiable(result);
  }

  static const _plurals = <String, String>{
    'person': 'человек',
    'chair': 'стульев',
    'car': 'автомобилей',
    'bus': 'автобусов',
    'truck': 'грузовиков',
    'motorcycle': 'мотоциклов',
    'bike': 'велосипедов',
    'dog': 'собак',
    'tree': 'деревьев',
    'dustbin': 'мусорных баков',
    'bench': 'скамеек',
    'fire hydrant': 'гидрантов',
    'plant pot': 'цветочных горшков',
    'electrical box': 'электрических шкафов',
    'bicycle rack': 'велосипедных стоек',
    'electrical pole': 'столбов',
    'traffic cone': 'дорожных конусов',
    'guard rail': 'ограждений',
    'traffic barrel': 'дорожных ограждений',
  };
}
