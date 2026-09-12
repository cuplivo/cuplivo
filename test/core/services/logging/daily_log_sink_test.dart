import 'dart:io';

import 'package:Cuplivo/core/services/logging/daily_log_sink.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'cuplivo_daily_log_sink_test_',
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<IOSink> open(
    Directory logsDir,
    DateTime now, {
    String activeFileName = 'logs.txt',
    String rotatedFilePrefix = 'logs_',
  }) {
    return openDailyRotatingLogSink(
      logsDir: logsDir,
      activeFileName: activeFileName,
      rotatedFilePrefix: rotatedFilePrefix,
      now: now,
    );
  }

  test('creates the logs directory and appends to the active file', () async {
    final logsDir = Directory(p.join(tempDir.path, 'logs'));
    final sink = await open(logsDir, DateTime(2026, 9, 12, 8));
    sink.write('hello');
    await sink.flush();
    await sink.close();

    expect(await logsDir.exists(), isTrue);
    expect(
      await File(p.join(logsDir.path, 'logs.txt')).readAsString(),
      'hello',
    );
  });

  test('rotates an active file whose last write was an earlier day', () async {
    final logsDir = Directory(p.join(tempDir.path, 'logs'));
    await logsDir.create(recursive: true);
    final active = File(p.join(logsDir.path, 'logs.txt'));
    await active.writeAsString('old', flush: true);
    await active.setLastModified(DateTime(2026, 9, 10, 23, 59));

    final sink = await open(logsDir, DateTime(2026, 9, 12, 8));
    await sink.close();

    final rotated = File(p.join(logsDir.path, 'logs_2026-09-10.txt'));
    expect(await rotated.exists(), isTrue);
    expect(await rotated.readAsString(), 'old');
    // The append sink re-creates the active file for the new day.
    expect(await active.readAsString(), '');
  });

  test('collision probe appends a numeric suffix', () async {
    final logsDir = Directory(p.join(tempDir.path, 'logs'));
    await logsDir.create(recursive: true);
    await File(
      p.join(logsDir.path, 'logs_2026-09-10.txt'),
    ).writeAsString('first', flush: true);
    final active = File(p.join(logsDir.path, 'logs.txt'));
    await active.writeAsString('second', flush: true);
    await active.setLastModified(DateTime(2026, 9, 10, 23, 59));

    final sink = await open(logsDir, DateTime(2026, 9, 12, 8));
    await sink.close();

    final rotated = File(p.join(logsDir.path, 'logs_2026-09-10_1.txt'));
    expect(await rotated.exists(), isTrue);
    expect(await rotated.readAsString(), 'second');
  });

  test('keeps an active file from the same day in place', () async {
    final logsDir = Directory(p.join(tempDir.path, 'logs'));
    await logsDir.create(recursive: true);
    final active = File(p.join(logsDir.path, 'logs.txt'));
    await active.writeAsString('today', flush: true);
    await active.setLastModified(DateTime(2026, 9, 12, 0, 1));

    final sink = await open(logsDir, DateTime(2026, 9, 12, 23, 59));
    sink.write('+');
    await sink.flush();
    await sink.close();

    expect(await active.readAsString(), 'today+');
    expect(
      await File(p.join(logsDir.path, 'logs_2026-09-12.txt')).exists(),
      isFalse,
    );
  });
}
