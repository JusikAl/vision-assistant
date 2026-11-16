import 'package:flutter_test/flutter_test.dart';
import 'package:yolo_live_detection/services/safety_service.dart';

Map<String, dynamic> object(
  String name, {
  double x = 40,
  double confidence = .9,
  double width = 20,
}) => {
  'class_name': name,
  'confidence': confidence,
  'bbox': [x, 30.0, x + width, 80.0],
};

void main() {
  late DateTime now;
  late SafetyService service;
  setUp(() {
    now = DateTime(2026);
    service = SafetyService(clock: () => now);
  });
  List<SafetyAlert> frame(
    List<dynamic> objects, {
    bool depth = false,
    double age = 0,
  }) => service.evaluate(
    detections: objects,
    imageWidth: 100,
    imageHeight: 100,
    allowReliableDepth: depth,
    frameAgeMs: age,
  );
  List<SafetyAlert> confirm(List<dynamic> objects, {bool depth = false}) {
    frame(objects, depth: depth);
    now = now.add(const Duration(milliseconds: 300));
    return frame(objects, depth: depth);
  }

  test('requires two stable frames; never warns from one detection', () {
    expect(frame([object('Stairs')]), isEmpty);
    now = now.add(const Duration(milliseconds: 300));
    expect(frame([object('Stairs', x: 41)]).single.text, 'Впереди лестница');
  });
  test('direction comes from center; priority does not come from box size', () {
    final alerts = confirm([
      object('Car', x: 1, width: 2),
      object('Car', x: 75),
    ]);
    expect(
      alerts.map((a) => a.text),
      containsAll(['Слева автомобиль', 'Справа автомобиль']),
    );
    expect(alerts.every((a) => a.priority == 2), isTrue);
  });
  test('class priorities and road context are distinct', () {
    final alerts = confirm([
      object('Person'),
      object('Car'),
      object('Stairs'),
      object('Road'),
      object('Building'),
      object('Pedestrian crosswalk'),
    ]);
    expect(alerts.map((a) => a.priority), [3, 2, 1]);
    expect(alerts.first.text, 'Впереди лестница');
  });
  test(
    'low confidence, non-finite, malformed and unknown objects are rejected',
    () {
      expect(
        confirm([
          object('Person', confidence: .59),
          object('Car', confidence: double.nan),
          object('Dog', confidence: 1.2),
          {
            'class_name': 'Car',
            'confidence': .9,
            'bbox': [0, 0, 0, 1],
          },
          {
            'class_name': 'Car',
            'confidence': .9,
            'bbox': [0, 0, double.infinity, 1],
          },
          object('unknown'),
          object('Car', x: -3),
        ]),
        isEmpty,
      );
    },
  );
  test('unstable or missing boxes cannot accumulate confirmation', () {
    frame([object('Person', x: 1)]);
    now = now.add(const Duration(milliseconds: 300));
    expect(frame([object('Person', x: 75)]), isEmpty);
    frame([]);
    now = now.add(const Duration(milliseconds: 300));
    expect(frame([object('Person', x: 75)]), isEmpty);
  });
  test('same timestamp and a long frame gap cannot confirm', () {
    frame([object('Car')]);
    expect(frame([object('Car')]), isEmpty);
    now = now.add(const Duration(seconds: 2));
    expect(frame([object('Car')]), isEmpty);
  });
  test('direction hysteresis suppresses boundary jitter', () {
    frame([object('Person', x: 20)]); // center .30, left
    now = now.add(const Duration(milliseconds: 300));
    expect(frame([object('Person', x: 24)]).single.key, 'person:left');
    now = now.add(const Duration(milliseconds: 300));
    expect(frame([object('Person', x: 25)]).single.key, 'person:left');
  });
  test('duplicate objects coalesce and cannot confirm in one frame', () {
    expect(frame([object('Car'), object('Car')]), isEmpty);
    now = now.add(const Duration(milliseconds: 300));
    expect(frame([object('Car'), object('Car')]), hasLength(1));
  });
  test('each same-class object must be matched independently', () {
    frame([object('Person', x: 1)]);
    now = now.add(const Duration(milliseconds: 300));
    final alerts = frame([object('Person', x: 1), object('Person', x: 75)]);
    expect(alerts, hasLength(1));
    expect(alerts.single.key, 'person:left');
  });
  test(
    'reset and stale frame clear evidence, including across mode changes',
    () {
      expect(confirm([object('Stairs')]), isNotEmpty);
      service.reset();
      expect(frame([object('Stairs')]), isEmpty);
      expect(frame([object('Stairs')], age: 2000), isEmpty);
      now = now.add(const Duration(milliseconds: 300));
      expect(frame([object('Stairs')]), isEmpty);
    },
  );
  test('experimental distance alone is never spoken', () {
    final detection = object('Car')..['distance_m'] = .5;
    expect(confirm([detection], depth: true).single.text, 'Впереди автомобиль');
  });
  test(
    'distance needs explicit reliable metric metadata, never used offline',
    () {
      final detection = object('Car')
        ..addAll({
          'distance_m': 2.5,
          'distance_reliable': true,
          'distance_confidence': .9,
          'distance_age_ms': 200,
          'distance_source': 'sensor_metric',
        });
      expect(confirm([detection]).single.text, 'Впереди автомобиль');
      expect(frame([detection], depth: true).single.text, contains('2,5'));
      detection['distance_age_ms'] = 1500;
      expect(frame([detection], depth: true).single.text, 'Впереди автомобиль');
    },
  );
  test(
    'trained barrel spelling is canonicalized; empty scene makes no claims',
    () {
      expect(
        confirm([object('Teraffic Barrel')]).single.key,
        'traffic barrel:center',
      );
      expect(frame([]), isEmpty);
    },
  );
  test('invalid frame age resets confirmed critical evidence', () {
    expect(confirm([object('Stairs')]), hasLength(1));
    expect(frame([object('Stairs')], age: double.nan), isEmpty);
    now = now.add(const Duration(milliseconds: 300));
    expect(frame([object('Stairs')]), isEmpty);
    now = now.add(const Duration(milliseconds: 300));
    final alerts = frame([object('Stairs')]);
    expect(alerts, hasLength(1));
    expect(alerts.single.priority, 3);
    expect(alerts.single.text, isNot(contains('метр')));
  });
}
