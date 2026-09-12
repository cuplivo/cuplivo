import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../../utils/app_directories.dart';
import 'daily_log_sink.dart';

class FlutterLogger {
  FlutterLogger._();

  /// Append target of the current day. Consumers match app logs by
  /// [activeFileName] or [rotatedFilePrefix]; the log viewer also uses it to
  /// badge the current file.
  static const String activeFileName = 'flutter_logs.txt';

  /// Prefix shared by rotated app logs (`flutter_logs_yyyy-MM-dd.txt`).
  static const String rotatedFilePrefix = 'flutter_logs_';

  static bool _enabled = false;
  static bool get enabled => _enabled;
  static bool _writeErrorReported = false;

  static Future<void> setEnabled(bool v) async {
    if (_enabled == v) return;
    _enabled = v;
    if (!v) {
      try {
        await _sink?.flush();
      } catch (_) {}
      try {
        await _sink?.close();
      } catch (_) {}
      _sink = null;
      _sinkDate = null;
    } else {
      _writeErrorReported = false;
    }
  }

  static bool _installed = false;
  static FlutterExceptionHandler? _originalFlutterOnError;
  static bool Function(Object, StackTrace)? _originalPlatformOnError;

  static void installGlobalHandlers() {
    if (_installed) return;
    _installed = true;

    _originalFlutterOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      try {
        log(details.toString().trimRight(), tag: 'FlutterError');
      } catch (_) {}

      final original = _originalFlutterOnError;
      if (original != null) {
        original(details);
      } else {
        FlutterError.dumpErrorToConsole(details);
      }
    };

    _originalPlatformOnError = ui.PlatformDispatcher.instance.onError;
    ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      try {
        // force: uncaught root-isolate errors are written to the log file even
        // when the log toggle is off, so release crashes remain diagnosable.
        log('$error\n$stack', tag: 'Uncaught', force: true);
      } catch (_) {}
      try {
        debugPrint('[Uncaught] $error\n$stack');
      } catch (_) {}

      final original = _originalPlatformOnError;
      if (original != null) return original(error, stack);
      // Returning true keeps the isolate alive. With the default `false` the
      // engine terminates the process on the first unhandled root-isolate
      // error, which surfaces as a silent window close in release builds.
      return true;
    };
  }

  static IOSink? _sink;
  static DateTime? _sinkDate;
  static Future<void> _writeQueue = Future<void>.value();

  static String _two(int v) => v.toString().padLeft(2, '0');
  static DateTime _dayOf(DateTime dt) => DateTime(dt.year, dt.month, dt.day);
  static String _formatDate(DateTime dt) =>
      '${dt.year}-${_two(dt.month)}-${_two(dt.day)}';
  static String _formatTs(DateTime dt) {
    return '${_formatDate(dt)} ${_two(dt.hour)}:${_two(dt.minute)}:${_two(dt.second)}.${dt.millisecond.toString().padLeft(3, '0')}';
  }

  static Future<IOSink> _ensureSink() async {
    final now = DateTime.now();
    final today = _dayOf(now);
    if (_sink != null && _sinkDate == today) return _sink!;

    try {
      await _sink?.flush();
    } catch (_) {}
    try {
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    _sinkDate = today;

    final logsDir = await AppDirectories.getLogsDirectory();
    _sink = await openDailyRotatingLogSink(
      logsDir: logsDir,
      activeFileName: activeFileName,
      rotatedFilePrefix: rotatedFilePrefix,
      now: now,
    );
    return _sink!;
  }

  static void log(String message, {String? tag, bool force = false}) {
    if (!_enabled && !force) return;
    final now = DateTime.now();
    final prefix = '[${_formatTs(now)}]${tag == null ? '' : ' [$tag]'} ';
    final normalized = message.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    final buffer = StringBuffer();
    for (final line in lines) {
      buffer.writeln('$prefix$line');
    }
    final text = buffer.toString();

    _writeQueue = _writeQueue.then((_) async {
      if (!_enabled && !force) return;
      try {
        final sink = await _ensureSink();
        sink.write(text);
        await sink.flush();
      } catch (_) {
        try {
          await _sink?.flush();
        } catch (_) {}
        try {
          await _sink?.close();
        } catch (_) {}
        _sink = null;
        _sinkDate = null;
        if (!_writeErrorReported) {
          _writeErrorReported = true;
          try {
            stderr.writeln(
              '[FlutterLogger] write failed; further write errors will be suppressed.',
            );
          } catch (_) {}
        }
      }
    });
  }

  static void logPrint(String line) {
    log(line, tag: 'print');
  }
}
