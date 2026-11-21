import 'package:flutter_test/flutter_test.dart';
import 'package:yolo_live_detection/services/safety_service.dart';
import 'package:yolo_live_detection/services/smart_scene_analyzer.dart';

void main() {
  late DateTime now;
  late SafetyService service;
  setUp(() {
    now = DateTime(2026);
    service = SafetyService(clock: () => now);
  });
  List<Map<String, dynamic>> people(int count) => List.generate(
    count,
    (i) => {
      'class_name': 'person',
      'confidence': .9,
      'bbox': [i * 10.0, 10.0, i * 10.0 + 6, 80.0],
    },
  );
  List<SafetyAlert> frame(List<dynamic> objects, {double age = 0}) {
    now = now.add(const Duration(milliseconds: 310));
    return service.evaluate(
      detections: objects,
      imageWidth: 100,
      imageHeight: 100,
      frameAgeMs: age,
    );
  }

  List<SafetyAlert> confirm(List<dynamic> objects) {
    frame(objects);
    return frame(objects);
  }

  test('single, two, five and crowded people produce one message', () {
    for (final n in [1, 2, 5, 9]) {
      service.reset();
      final alerts = confirm(people(n));
      expect(alerts, hasLength(1));
      expect(
        alerts.single.text,
        n >= 5
            ? contains('группа людей')
            : n == 1
            ? contains('человек')
            : contains('несколько человек'),
      );
    }
  });
  test('mixed sides and one center give unambiguous group direction', () {
    final objects = people(3);
    objects[1]['bbox'] = [46.0, 10.0, 54.0, 80.0];
    objects[2]['bbox'] = [86.0, 10.0, 94.0, 80.0];
    expect(
      confirm(objects).single.text,
      'Впереди несколько человек, один по центру',
    );
  });
  test('partial loss is tolerated then group wording updates', () {
    final objects = people(3);
    expect(confirm(objects).single.text, contains('несколько'));
    expect(frame(objects.take(1).toList()).single.text, contains('несколько'));
    frame(objects.take(1).toList());
    expect(
      frame(objects.take(1).toList()).single.text,
      isNot(contains('несколько')),
    );
  });
  test('stale, empty and reset scenes never claim free space', () {
    confirm(people(5));
    expect(frame(people(5), age: 1501), isEmpty);
    expect(service.describeScene(), contains('Нет свежих'));
    expect(frame([]), isEmpty);
    expect(frame(people(5)), isEmpty);
    frame(people(5));
    now = now.add(const Duration(seconds: 2));
    expect(service.describeScene(), contains('Нет свежих'));
    service.reset();
    expect(frame(people(5)), isEmpty);
  });
  test('cars rank above people and critical tracks bypass grouping', () {
    final objects = <dynamic>[
      ...people(5),
      {
        'class_name': 'car',
        'confidence': .9,
        'bbox': [40, 10, 60, 80],
      },
      {
        'class_name': 'stairs',
        'confidence': .9,
        'bbox': [40, 10, 60, 80],
      },
      {
        'class_name': 'stairs',
        'confidence': .9,
        'bbox': [75, 10, 95, 80],
      },
    ];
    final alerts = confirm(objects);
    expect(alerts.map((a) => a.priority), [3, 3, 2, 1]);
    expect(alerts[0].key, isNot(alerts[1].key));
    final key = alerts[0].key;
    expect(frame(objects).first.key, key);
  });
  test('boundaries are configurable and retain a stable side', () {
    final analyzer = SmartSceneAnalyzer();
    expect(analyzer.side(.34), 'left');
    expect(analyzer.side(.36, 'left'), 'left');
    expect(analyzer.side(.39, 'left'), 'center');
    expect(analyzer.side(.64, 'right'), 'right');
    expect(SmartSceneAnalyzer(leftBoundary: .2).side(.3), 'center');
  });
  test('duplicate boxes do not inflate group counts', () {
    final objects = people(1);
    expect(
      confirm([...objects, ...objects]).single.text,
      isNot(contains('несколько')),
    );
  });

  test('critical identity survives one partial-result dropout', () {
    final stair = {
      'class_name': 'stairs',
      'confidence': .9,
      'bbox': [40, 10, 60, 80],
    };
    final objects = <dynamic>[...people(2), stair];
    final key = confirm(objects).first.key;
    frame(people(2));
    expect(frame(objects).first.key, key);
  });

  test('group wording cannot outlive its supporting evidence', () {
    final objects = people(3);
    confirm(objects);
    now = now.add(const Duration(milliseconds: 1100));
    frame(objects.take(1).toList());
    final single = frame(objects.take(1).toList());
    expect(single.single.text, isNot(contains('несколько')));
  });
}
