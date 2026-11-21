// flutter run --profile -t tool/whisper_device_smoke.dart
//   --dart-define=OFFLINE_ONLY=true -d <arm64-device>
// Synthetic offline Android TTS fixtures, not live human acceptance testing.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yolo_live_detection/app_config.dart';
import 'package:yolo_live_detection/live_camera_page.dart';
import 'package:yolo_live_detection/services/whisper_service.dart';
import 'package:yolo_live_detection/services/voice_command_parser.dart';

void emit(String kind, Object data) =>
    debugPrint('WHISPER TEST $kind ${jsonEncode(data)}');
Future<void> waitFor(bool Function() ready) async {
  final timer = Stopwatch()..start();
  while (!ready()) {
    if (timer.elapsed > const Duration(seconds: 60)) {
      throw TimeoutException('Camera/model not ready');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!const bool.fromEnvironment('OFFLINE_ONLY')) {
    throw StateError('Offline-only test');
  }
  await AppConfig.load();
  final key = GlobalKey();
  runApp(MaterialApp(home: LiveCameraPage(key: key)));
  unawaited(exercise(key));
}

Uint8List pcm16(Uint8List wav) {
  final data = ByteData.sublistView(wav);
  int rate = 0, channels = 0, bits = 0, start = 0, size = 0;
  for (var offset = 12; offset + 8 <= wav.length;) {
    final name = String.fromCharCodes(wav.sublist(offset, offset + 4));
    final length = data.getUint32(offset + 4, Endian.little);
    if (name == 'fmt ') {
      if (data.getUint16(offset + 8, Endian.little) != 1) {
        throw StateError('PCM WAV required');
      }
      channels = data.getUint16(offset + 10, Endian.little);
      rate = data.getUint32(offset + 12, Endian.little);
      bits = data.getUint16(offset + 22, Endian.little);
    }
    if (name == 'data') {
      start = offset + 8;
      size = min(length, wav.length - start);
      break;
    }
    offset += 8 + length + (length % 2);
  }
  if (bits != 16 || rate <= 0 || channels <= 0 || start == 0) {
    throw StateError('Invalid WAV');
  }
  final frames = size ~/ 2 ~/ channels;
  final count = min(72000, (frames * 16000 / rate).floor());
  final pcm = ByteData(
    (count + 8000) * 2,
  ); // 0.2s lead + 0.3s tail, max 5 seconds
  for (var i = 0; i < count; i++) {
    final index = min(frames - 1, (i * rate / 16000).floor());
    var sum = 0;
    for (var c = 0; c < channels; c++) {
      sum += data.getInt16(start + (index * channels + c) * 2, Endian.little);
    }
    pcm.setInt16((i + 3200) * 2, sum ~/ channels, Endian.little);
  }
  return pcm.buffer.asUint8List();
}

Future<void> exercise(GlobalKey key) async {
  try {
    await waitFor(() => key.currentState != null);
    final dynamic state = key.currentState;
    await waitFor(() => state.controller?.value.isInitialized == true);
    final WhisperService whisper = state.diagnosticWhisper as WhisperService;
    final load = Stopwatch()..start();
    await whisper.initialize();
    emit('load', {
      'wall_ms': load.elapsedMilliseconds,
      'native_ms': whisper.loadMs,
    });
    await state.startDetection();
    await waitFor(() => state.lastResult != null);
    const fixture = MethodChannel('navigation/whisper_validation');
    final phrases = <VoiceCommand, List<String>>{
      VoiceCommand.start: ['Начать', 'Начни', 'Запусти', 'Начать обнаружение'],
      VoiceCommand.stop: [
        'Остановить',
        'Останови',
        'Стоп',
        'Остановить обнаружение',
      ],
      VoiceCommand.describe: [
        'Что впереди',
        'Что передо мной',
        'Что ты видишь',
        'Опиши окружение',
      ],
      VoiceCommand.repeat: ['Повтори', 'Повторить', 'Ещё раз', 'Скажи снова'],
    };
    final base = <Uint8List>[];
    const performanceOnly = bool.fromEnvironment('WHISPER_PERF_ONLY');
    var correct = 0, total = 0;
    for (final entry in phrases.entries) {
      for (
        var attempt = 0;
        attempt <
            (performanceOnly
                ? 1
                : const int.fromEnvironment(
                    'WHISPER_ATTEMPTS',
                    defaultValue: 10,
                  ));
        attempt++
      ) {
        final phrase = entry.value[attempt % entry.value.length];
        final bytes = await fixture.invokeMethod<Uint8List>('fixture', {
          'text': phrase,
          'rate': .85 + (attempt % 4) * .1,
        });
        final pcm = pcm16(bytes!);
        if (attempt == 0) base.add(Uint8List.fromList(pcm));
        if (performanceOnly) continue;
        final view = ByteData.sublistView(pcm), random = Random(100 + total);
        for (var i = 0; i < pcm.length; i += 2) {
          var value = view.getInt16(i, Endian.little).toDouble();
          if (attempt % 3 == 1) value *= .25;
          if (attempt % 3 == 2) value += (random.nextDouble() * 2 - 1) * 160;
          view.setInt16(i, value.round().clamp(-32768, 32767), Endian.little);
        }
        final timer = Stopwatch()..start();
        String? text;
        await waitFor(
          () => !whisper.isProcessing && whisper.state.name != 'speaking',
        );
        try {
          text = await whisper.transcribe(pcm);
        } catch (error) {
          emit('transcribe_error', error.toString());
        }
        final matched = VoiceCommandParser.parse(text ?? '') == entry.key;
        if (matched) correct++;
        total++;
        emit('command', {
          'expected': entry.key.name,
          'phrase': phrase,
          'attempt': attempt,
          'condition': attempt % 3 == 0
              ? 'normal'
              : attempt % 3 == 1
              ? 'quiet'
              : 'added_noise',
          'text': text,
          'matched': matched,
          'wall_ms': timer.elapsedMilliseconds,
          'inference_ms': whisper.recognitionMs,
          'avg_logprob': whisper.averageLogProbability,
          'no_speech_prob': whisper.noSpeechProbability,
        });
      }
    }
    emit(performanceOnly ? 'performance_setup' : 'accuracy', {
      'correct': correct,
      'total': total,
      'source': 'synthetic Android offline TTS; no acoustic microphone loop',
    });
    for (final phrase
        in performanceOnly
            ? const <String>[]
            : [
                'Какая сегодня погода',
                'Не начинай',
                'Не останавливай',
                'Привет',
              ]) {
      final bytes = await fixture.invokeMethod<Uint8List>('fixture', {
        'text': phrase,
        'rate': 1.0,
      });
      await waitFor(
        () => !whisper.isProcessing && whisper.state.name != 'speaking',
      );
      final text = await whisper.transcribe(pcm16(bytes!));
      emit('unknown', {
        'phrase': phrase,
        'text': text,
        'command': VoiceCommandParser.parse(text ?? '').name,
      });
    }
    if (performanceOnly) {
      await waitFor(
        () => !whisper.isProcessing && whisper.state.name != 'speaking',
      );
      try {
        await whisper.transcribe(base.first);
      } catch (_) {}
      await waitFor(() => !whisper.isProcessing);
    }
    // Same camera, model resident in both conditions. Counterbalanced CPU load.
    for (final mode in [false, true, true, false]) {
      final samples = <double>[];
      DateTime? previous = state.lastResult as DateTime?;
      var count = 0, finished = false;
      Future<void> loadWhisper() async {
        while (!finished) {
          try {
            await whisper.transcribe(base[count % base.length]);
          } catch (_) {}
          count++;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      final watch = Stopwatch()..start();
      final inference = mode ? loadWhisper() : Future<void>.value();
      while (watch.elapsed <
          const Duration(
            seconds: int.fromEnvironment(
              'WHISPER_WINDOW_SECONDS',
              defaultValue: 20,
            ),
          )) {
        final current = state.lastResult as DateTime?;
        if (current != null && current != previous) {
          previous = current;
          samples.add(state.cameraToResultMs as double);
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      finished = true;
      final duration = watch.elapsedMilliseconds;
      samples.sort();
      emit('performance', {
        'whisper_active': mode,
        'window_ms': duration,
        'results': samples.length,
        'results_per_second': samples.length * 1000 / duration,
        'rss_bytes': ProcessInfo.currentRss,
        'yolo_p50_ms': samples.isEmpty ? null : samples[samples.length ~/ 2],
        'yolo_p95_ms': samples.isEmpty
            ? null
            : samples[((samples.length - 1) * .95).ceil()],
      });
      await inference;
    }
    emit('silence', {'text': await whisper.transcribe(Uint8List(32000))});
    // Actual microphone opens and closes; ambient result is logged, never acted on.
    final recording = whisper.startListening();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final opened = whisper.isListening;
    await whisper.cancel();
    emit('record_cancel', {
      'result': await recording,
      'state': whisper.state.name,
      'opened': opened,
    });
    await state.stopDetection();
    await state.startDetection();
    await waitFor(() => state.lastResult != null);
    await state.stopDetection();
    emit('complete', {'status': 'complete'});
  } catch (error, stack) {
    emit('error', {'error': error.toString(), 'stack': stack.toString()});
  }
}
