import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Host-side driver for the Android E2E acceptance scenario.
///
/// `flutter drive` runs this on the host; each `binding.takeScreenshot(name)`
/// in the test sends PNG bytes here and this callback writes them to
/// `E2E_OUTPUT` (default `build/e2e/screenshots`). The workflow uploads that
/// directory as the `e2e-screenshots` artifact.
///
/// The screenshots are evidence for a human reviewer, not a pixel baseline:
/// the driver never compares them and returns `true` for every capture.
///
/// Set `E2E_SCREENSHOT_MODE=adb` to capture the device screen with
/// `adb exec-out screencap` instead of the Flutter surface. The test still
/// calls `takeScreenshot` so the two sides stay in step; this mode exists for
/// renderers where the Flutter-surface capture comes out blank, and it also
/// includes system UI/WebView content.
Future<void> main() async {
  final startedAt = DateTime.now().toUtc().toIso8601String();
  final captures = <Map<String, Object?>>[];
  await integrationDriver(
    onScreenshot: (name, bytes, [args]) async {
      final directory = Directory(_outputDirectory());
      await directory.create(recursive: true);
      final safeName = _safeName(name);
      final captured = await _capture(safeName, bytes);
      final file = File('${directory.path}/$safeName.png');
      await file.writeAsBytes(captured, flush: true);
      captures.add({
        'name': safeName,
        'epochMs': DateTime.now().millisecondsSinceEpoch,
        'bytes': captured.length,
      });
      await _writeManifest(directory, startedAt, captures);
      stdout.writeln('E2E screenshot: ${file.path} (${captured.length} bytes)');
      return true;
    },
    writeResponseOnFailure: true,
  );
  await _writeManifest(
    Directory(_outputDirectory()),
    startedAt,
    captures,
    endedAt: DateTime.now().toUtc().toIso8601String(),
  );
}

/// The screenshot name comes from test code inside a pull request, so it is
/// untrusted input: never let it choose a path outside the output directory.
String _safeName(String name) {
  final sanitized = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  if (sanitized.isEmpty || sanitized.startsWith('.')) {
    return 'screenshot';
  }
  return sanitized.length <= 120 ? sanitized : sanitized.substring(0, 120);
}

String _outputDirectory() {
  final configured = Platform.environment['E2E_OUTPUT'];
  if (configured == null || configured.isEmpty) {
    return 'build/e2e/screenshots';
  }
  // The emulator step sets E2E_OUTPUT to the run root (screenshots, video and
  // logs live under it); keep a path that already names the screenshot
  // directory as-is.
  final root = configured.replaceAll(RegExp(r'[\\/]+$'), '');
  return root.endsWith('/screenshots') ? root : '$root/screenshots';
}

Future<List<int>> _capture(String name, List<int> flutterBytes) async {
  if (Platform.environment['E2E_SCREENSHOT_MODE'] != 'adb') {
    return flutterBytes;
  }
  final device = Platform.environment['E2E_DEVICE'] ?? 'emulator-5554';
  try {
    final result = await Process.run('adb', [
      '-s',
      device,
      'exec-out',
      'screencap',
      '-p',
    ], stdoutEncoding: null);
    final bytes = result.stdout;
    if (result.exitCode == 0 && bytes is List<int> && bytes.isNotEmpty) {
      return bytes;
    }
    stderr.writeln(
      'E2E: adb screencap for "$name" failed (exit ${result.exitCode}); '
      'keeping the Flutter surface capture.',
    );
  } catch (error) {
    stderr.writeln('E2E: adb screencap for "$name" failed: $error');
  }
  return flutterBytes;
}

Future<void> _writeManifest(
  Directory directory,
  String startedAt,
  List<Map<String, Object?>> captures, {
  String? endedAt,
}) async {
  final file = File('${directory.path}/screenshots.json');
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'startedAt': startedAt,
      if (endedAt != null) 'endedAt': endedAt,
      'screenshots': captures,
    }),
    flush: true,
  );
}
