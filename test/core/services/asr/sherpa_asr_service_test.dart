import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/asr/sherpa_asr_service.dart';

void main() {
  group('SherpaAsrService.pcm16ToFloat32', () {
    test('decodes signed little-endian mono samples', () {
      final samples = SherpaAsrService.pcm16ToFloat32(
        Uint8List.fromList([0x00, 0x80, 0xff, 0xff, 0x00, 0x00, 0xff, 0x7f]),
      );

      expect(samples[0], -1);
      expect(samples[1], closeTo(-1 / 32768, 0.0000001));
      expect(samples[2], 0);
      expect(samples[3], closeTo(32767 / 32768, 0.0000001));
    });

    test('respects a typed-data view offset', () {
      final backing = Uint8List.fromList([9, 9, 0x00, 0x40, 9]);
      final view = Uint8List.sublistView(backing, 2, 4);

      final samples = SherpaAsrService.pcm16ToFloat32(view);

      expect(samples, hasLength(1));
      expect(samples.single, 0.5);
    });

    test('rejects a partial PCM16 sample', () {
      expect(
        () => SherpaAsrService.pcm16ToFloat32(Uint8List.fromList([1])),
        throwsA(isA<FormatException>()),
      );
    });
  });

  test('requires a positive native thread count', () {
    expect(() => SherpaAsrService(numThreads: 0), throwsArgumentError);
  });

  group('SherpaAsrService.preparePcm16ForRecognition', () {
    test('rejects silence and captures that are too short', () {
      expect(
        SherpaAsrService.preparePcm16ForRecognition(
          Uint8List(16000 * 2),
          sampleRate: 16000,
        ),
        isNull,
      );
      expect(
        SherpaAsrService.preparePcm16ForRecognition(
          _sinePcm16(sampleRate: 16000, seconds: 0.2),
          sampleRate: 16000,
        ),
        isNull,
      );
    });

    test('keeps sustained speech energy and trims quiet edges', () {
      const sampleRate = 16000;
      final leadingSilence = Uint8List((sampleRate * 0.5).round() * 2);
      final speech = _sinePcm16(sampleRate: sampleRate, seconds: 0.6);
      final trailingSilence = Uint8List((sampleRate * 0.5).round() * 2);
      final capture = Uint8List.fromList([
        ...leadingSilence,
        ...speech,
        ...trailingSilence,
      ]);

      final prepared = SherpaAsrService.preparePcm16ForRecognition(
        capture,
        sampleRate: sampleRate,
      );

      expect(prepared, isNotNull);
      expect(prepared!.length, lessThan(capture.length));
      expect(prepared.length, greaterThanOrEqualTo(speech.length));
    });

    test('rejects sustained background energy and scattered clicks', () {
      const sampleRate = 16000;
      final background = Uint8List(sampleRate * 2);
      final backgroundData = ByteData.sublistView(background);
      for (var index = 0; index < sampleRate; index++) {
        backgroundData.setInt16(
          index * 2,
          index.isEven ? 12000 : -12000,
          Endian.little,
        );
      }

      final clicks = Uint8List(sampleRate * 2);
      final clickData = ByteData.sublistView(clicks);
      final frameSamples = sampleRate ~/ 50;
      for (var frame = 0; frame < 16; frame += 2) {
        final start = frame * frameSamples;
        for (var index = start; index < start + frameSamples; index++) {
          clickData.setInt16(index * 2, 6000, Endian.little);
        }
      }

      expect(
        SherpaAsrService.preparePcm16ForRecognition(
          background,
          sampleRate: sampleRate,
        ),
        isNull,
      );
      expect(
        SherpaAsrService.preparePcm16ForRecognition(
          clicks,
          sampleRate: sampleRate,
        ),
        isNull,
      );
    });

    test('silent audio returns before loading a model', () async {
      final service = SherpaAsrService();

      expect(
        await service.transcribePcm16(
          modelId: 'not-installed',
          pcm16: Uint8List(16000 * 2),
          sampleRate: 16000,
        ),
        isEmpty,
      );
    });
  });
}

Uint8List _sinePcm16({required int sampleRate, required double seconds}) {
  final sampleCount = (sampleRate * seconds).round();
  final result = Uint8List(sampleCount * 2);
  final data = ByteData.sublistView(result);
  for (var index = 0; index < sampleCount; index++) {
    final sample = (math.sin(2 * math.pi * 220 * index / sampleRate) * 6000)
        .round();
    data.setInt16(index * 2, sample, Endian.little);
  }
  return result;
}
