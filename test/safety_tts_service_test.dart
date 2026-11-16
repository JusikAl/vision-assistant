import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yolo_live_detection/safety_tts_service.dart';

class FakeTts extends FlutterTts {
  final spoken = <String>[];
  final events = <String>[];
  final requests = <Completer<dynamic>>[];
  int setups = 0, stops = 0, active = 0, maxActive = 0;
  Completer<void>? stopGate;
  bool resolveSpeakOnStop = true;
  bool hasOfflineVoice = true;
  int stopResult = 1;
  @override
  Future<dynamic> setLanguage(String language) async {
    setups++;
    return 1;
  }

  @override
  Future<dynamic> get getVoices async => [
    {'name': 'network', 'locale': 'ru-RU', 'network_required': '1'},
    if (hasOfflineVoice)
      {'name': 'local', 'locale': 'ru-RU', 'network_required': '0'},
  ];
  @override
  Future<dynamic> setVoice(Map<String, String> voice) async {
    events.add('voice:${voice['name']}');
    return 1;
  }

  @override
  Future<dynamic> setQueueMode(int queueMode) async => 1;
  @override
  Future<void> setAudioAttributesForNavigation() async {}
  @override
  Future<dynamic> setSpeechRate(double rate) async => 1;
  @override
  Future<dynamic> setPitch(double pitch) async => 1;
  @override
  Future<dynamic> setVolume(double volume) async => 1;
  @override
  Future<dynamic> awaitSpeakCompletion(bool awaitCompletion) async => 1;
  @override
  Future<dynamic> speak(String text, {bool focus = false}) {
    startHandler?.call();
    spoken.add(text);
    events.add('speak:$text');
    active++;
    if (active > maxActive) maxActive = active;
    final result = Completer<dynamic>();
    requests.add(result);
    return result.future;
  }

  void complete([int result = 1]) {
    active = 0;
    if (requests.isNotEmpty && !requests.last.isCompleted) {
      requests.last.complete(result);
    }
  }

  @override
  Future<dynamic> stop() async {
    stops++;
    events.add('stop:begin');
    await stopGate?.future;
    active = 0;
    if (resolveSpeakOnStop &&
        requests.isNotEmpty &&
        !requests.last.isCompleted) {
      requests.last.complete(0);
    }
    events.add('stop:end');
    return stopResult;
  }
}

void main() {
  late FakeTts native;
  late SafetyTtsService service;
  late DateTime now;
  setUp(() {
    native = FakeTts();
    now = DateTime(2026);
    service = SafetyTtsService(tts: native, clock: () => now);
  });
  SafetyAlert alert(String key, int priority) =>
      SafetyAlert(key: key, text: key, priority: priority, observedAt: now);

  void speechTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        final gate = native.stopGate;
        if (gate != null && !gate.isCompleted) gate.complete();
        native.stopGate = null;
        await service.dispose();
        await tester.pump();
      }
    });
  }

  speechTest('one offline voice, one engine, strongest alert first', (
    tester,
  ) async {
    service.onFrame([alert('person', 1), alert('stairs', 3), alert('car', 2)]);
    await tester.pump();
    expect(native.events.first, 'voice:local');
    expect(native.spoken, ['stairs']);
    native.complete();
    await tester.pump();
    expect(native.spoken, ['stairs', 'car']);
    native.complete();
    await tester.pump();
    expect(native.spoken.last, 'person');
    expect(native.setups, 1);
    expect(native.maxActive, 1);
  });

  speechTest('repeat suppressed during speech and until cooldown expires', (
    tester,
  ) async {
    service.onFrame([alert('stairs', 3)]);
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      service.onFrame([alert('stairs', 3)]);
    }
    await tester.pump();
    expect(native.spoken, hasLength(1));
    native.complete();
    await tester.pump();
    now = now.add(const Duration(seconds: 11));
    await tester.pump(const Duration(seconds: 11));
    service.onFrame([alert('stairs', 3)]);
    await tester.pump();
    expect(native.spoken, hasLength(1));
    now = now.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    service.onFrame([alert('stairs', 3)]);
    await tester.pump();
    expect(native.spoken, hasLength(2));
  });

  speechTest(
    'important warning interrupts scene description after native stop',
    (tester) async {
      final description = service.speakMessage('scene description');
      await tester.pump();
      native.stopGate = Completer<void>();
      service.onFrame([alert('stairs', 3)]);
      await tester.pump();
      expect(native.spoken, ['scene description']);
      native.stopGate!.complete();
      native.stopGate = null;
      await tester.pump();
      await description;
      expect(native.spoken, ['scene description', 'stairs']);
      expect(
        native.events.indexOf('stop:end'),
        lessThan(native.events.indexOf('speak:stairs')),
      );
      expect(native.maxActive, 1);
    },
  );

  speechTest(
    'low priority does not interrupt manual answer; warning can replace lower warning',
    (tester) async {
      final description = service.speakMessage('scene');
      await tester.pump();
      service.onFrame([alert('person', 1)]);
      await tester.pump();
      expect(native.stops, 0);
      native.complete();
      await tester.pump();
      await description;
      expect(native.spoken.last, 'person');
      service.onFrame([alert('person', 1), alert('car', 2)]);
      await tester.pump();
      expect(native.spoken.last, 'car');
      expect(native.maxActive, 1);
    },
  );

  speechTest('expired warning is never spoken after delayed stop', (
    tester,
  ) async {
    unawaited(service.speakMessage('scene'));
    await tester.pump();
    native.stopGate = Completer<void>();
    service.onFrame([alert('stairs', 3)]);
    await tester.pump();
    now = now.add(const Duration(milliseconds: 1900));
    await tester.pump(const Duration(milliseconds: 1900));
    native.stopGate!.complete();
    native.stopGate = null;
    await tester.pump();
    expect(native.spoken, ['scene']);
  });

  speechTest('disappeared or replaced scene cannot leave queued warnings', (
    tester,
  ) async {
    service.onFrame([alert('stairs', 3), alert('person', 1)]);
    await tester.pump();
    service.onFrame([]);
    await tester.pump();
    expect(native.spoken, ['stairs']);
    service.resetScene();
    service.onFrame([alert('stairs', 3)]);
    await tester.pump();
    expect(native.spoken, ['stairs']); // cooldown survives offline/online reset
  });

  speechTest(
    'stop clears jobs and restart reuses engine without hung speak future',
    (tester) async {
      native.resolveSpeakOnStop = false;
      service.onFrame([alert('stairs', 3)]);
      await tester.pump();
      await service.stop();
      await tester.pump();
      service.onFrame([alert('car', 2)]);
      await tester.pump();
      expect(native.spoken, ['stairs', 'car']);
      expect(native.setups, 1);
      expect(native.maxActive, 1);
    },
  );

  speechTest('only latest manual reply survives behind a warning', (
    tester,
  ) async {
    service.onFrame([alert('stairs', 3)]);
    await tester.pump();
    final old = service.speakMessage('old');
    final latest = service.speakMessage('latest');
    await old;
    native.complete();
    await tester.pump();
    expect(native.spoken, ['stairs', 'latest']);
    native.complete();
    await tester.pump();
    await latest;
  });

  speechTest('muting cancels automatic warnings but allows command replies', (
    tester,
  ) async {
    service.onFrame([alert('stairs', 3)]);
    await tester.pump();
    service.setEnabled(false);
    await tester.pump();
    service.onFrame([alert('car', 2)]);
    final reply = service.speakMessage('warnings disabled');
    await tester.pump();
    expect(native.spoken, ['stairs', 'warnings disabled']);
    native.complete();
    await tester.pump();
    await reply;
  });

  speechTest('missing offline voice never falls back to a network voice', (
    tester,
  ) async {
    native.hasOfflineVoice = false;
    service.onFrame([alert('stairs', 3)]);
    await tester.pump();
    expect(service.offlineVoiceReady, isFalse);
    expect(service.lastError, contains('offline Russian'));
    expect(native.spoken, isEmpty);
    for (var i = 0; i < 30; i++) {
      service.onFrame([alert('stairs', 3)]);
    }
    await tester.pump();
    expect(native.setups, 1); // no retry per frame
  });

  speechTest(
    'one missing frame does not chop speech; loss of evidence expires it',
    (tester) async {
      service.onFrame([alert('car', 2)]);
      await tester.pump();
      service.onFrame([]);
      await tester.pump();
      expect(native.stops, 0);
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      expect(native.stops, 1);
      expect(service.isSpeaking, isFalse);
    },
  );

  speechTest('old manual reply expires behind a sustained warning', (
    tester,
  ) async {
    service.onFrame([alert('stairs', 3)]);
    await tester.pump();
    final reply = service.speakMessage('old scene');
    for (var i = 0; i < 5; i++) {
      now = now.add(const Duration(seconds: 1));
      service.onFrame([alert('stairs', 3)]);
      await tester.pump(const Duration(seconds: 1));
    }
    await reply;
    native.complete();
    await tester.pump();
    expect(native.spoken, ['stairs']);
  });

  speechTest(
    'failed native stop blocks further audio and completes queued callers',
    (tester) async {
      service.onFrame([alert('stairs', 3)]);
      await tester.pump();
      final reply = service.speakMessage('queued');
      native.stopResult = 0;
      await service.stop();
      await tester.pump();
      await reply;
      await service.speakMessage('must not overlap');
      service.onFrame([alert('car', 2)]);
      await tester.pump();
      expect(native.spoken, ['stairs']);
      expect(service.offlineVoiceReady, isFalse);
    },
  );

  speechTest('detection-to-TTS confirms once and never awaits speech', (
    tester,
  ) async {
    final detections = [
      {
        'class_name': 'Car',
        'confidence': .9,
        'bbox': [10, 10, 30, 80],
      },
    ];
    expect(
      service.onDetections(
        detections: detections,
        imageWidth: 100,
        imageHeight: 100,
      ),
      isEmpty,
    );
    await tester.pump();
    now = now.add(const Duration(milliseconds: 300));
    expect(
      service.onDetections(
        detections: detections,
        imageWidth: 100,
        imageHeight: 100,
      ),
      hasLength(1),
    );
    await tester.pump();
    expect(native.spoken, ['Слева автомобиль']);
    for (var i = 0; i < 10; i++) {
      now = now.add(const Duration(milliseconds: 300));
      service.onDetections(
        detections: detections,
        imageWidth: 100,
        imageHeight: 100,
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(native.spoken, hasLength(1));
    expect(native.maxActive, 1);
  });

  speechTest(
    'speech failure is visible and a subsequent successful reply recovers',
    (tester) async {
      final reply = service.speakMessage('first');
      await tester.pump();
      native.errorHandler?.call('synthesis failed');
      native.complete(0);
      await tester.pump();
      await reply;
      expect(service.offlineVoiceReady, isFalse);
      expect(service.lastError, isNotNull);
      final recovered = service.speakMessage('retry');
      await tester.pump();
      native.complete();
      await tester.pump();
      await recovered;
      expect(service.offlineVoiceReady, isTrue);
      expect(service.lastError, isNull);
    },
  );
  speechTest('failed warning retries after short backoff, not full cooldown', (
    tester,
  ) async {
    service.onFrame([alert('stairs', 3)]);
    await tester.pump();
    native.complete(0);
    await tester.pump();
    service.onFrame([alert('stairs', 3)]);
    await tester.pump();
    expect(native.spoken, hasLength(1));
    now = now.add(const Duration(seconds: 3));
    service.onFrame([alert('stairs', 3)]);
    await tester.pump();
    expect(native.spoken, hasLength(2));
  });
  speechTest('audio ownership acquired before speak and released on stop', (
    tester,
  ) async {
    final gate = Completer<void>();
    final changes = <bool>[];
    service.onSpeakingChanged = (value) async {
      changes.add(value);
      if (value) await gate.future;
    };
    final message = service.speakMessage('test');
    await tester.pump();
    expect(changes, [true]);
    expect(native.spoken, isEmpty);
    gate.complete();
    await tester.pump();
    expect(native.spoken, ['test']);
    now = now.add(const Duration(milliseconds: 40));
    native.startHandler?.call();
    expect(service.lastResponseMs, 40);
    await service.stop();
    await tester.pump();
    await message;
    expect(changes, [true, false]);
  });
  speechTest('idle stop does not wait for disconnected Android TTS', (
    tester,
  ) async {
    await service.stop();
    expect(native.stops, 0);
    final reply = service.speakMessage('ready');
    await tester.pump();
    expect(native.spoken, ['ready']);
    native.complete();
    await tester.pump();
    await reply;
  });
}
