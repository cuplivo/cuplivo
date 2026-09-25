import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/asr/asr_audio_capture.dart';

void main() {
  test('normalizedPcm16Level maps silence to zero', () {
    expect(normalizedPcm16Level(Uint8List(32)), 0);
    expect(normalizedPcm16Level(Uint8List(1)), 0);
  });

  test('normalizedPcm16Level increases with PCM amplitude', () {
    Uint8List pcm(int value) {
      final result = Uint8List(64);
      final data = ByteData.sublistView(result);
      for (var offset = 0; offset < result.length; offset += 2) {
        data.setInt16(offset, value, Endian.little);
      }
      return result;
    }

    final quiet = normalizedPcm16Level(pcm(800));
    final speech = normalizedPcm16Level(pcm(8000));
    final loud = normalizedPcm16Level(pcm(30000));

    expect(quiet, greaterThan(0));
    expect(speech, greaterThan(quiet));
    expect(loud, greaterThan(speech));
    expect(loud, lessThanOrEqualTo(1));
  });
}
