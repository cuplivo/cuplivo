import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'sandbox_runtime.dart';

/// Shared WSL distro name used by all Windows Linux sandboxes.
const String kCuplivoWslDistroName = 'Cuplivo-Sandbox';

/// Windows ERROR_SUCCESS_REBOOT_REQUIRED
const int kWslRebootRequiredExitCode = 3010;

class WslProbeResult {
  /// `wsl.exe` is invokable (platform binary present).
  final bool available;

  /// WSL platform can list distros (installed / usable enough to proceed).
  final bool platformReady;

  /// Shared [kCuplivoWslDistroName] is registered.
  final bool cuplivoDistroReady;

  /// At least one distribution is registered.
  final bool anyDistroReady;

  final String? detail;
  final bool rebootRecommended;

  const WslProbeResult({
    required this.available,
    required this.platformReady,
    required this.cuplivoDistroReady,
    required this.anyDistroReady,
    this.detail,
    this.rebootRecommended = false,
  });
}

class WslEnableResult {
  final bool ok;
  final bool rebootRecommended;
  final String? detail;
  final int? exitCode;

  const WslEnableResult({
    required this.ok,
    this.rebootRecommended = false,
    this.detail,
    this.exitCode,
  });
}

/// Convert a Windows host path to a WSL mount path (`C:\x` → `/mnt/c/x`).
String hostPathToWsl(String windowsPath) {
  final trimmed = windowsPath.trim();
  if (trimmed.isEmpty) return trimmed;

  final normalized = trimmed.replaceAll('/', '\\');
  final driveMatch = RegExp(r'^([A-Za-z]):[\\]?(.*)$').firstMatch(normalized);
  if (driveMatch != null) {
    final drive = driveMatch.group(1)!.toLowerCase();
    var rest = driveMatch.group(2) ?? '';
    rest = rest.replaceAll('\\', '/');
    while (rest.startsWith('/')) {
      rest = rest.substring(1);
    }
    if (rest.endsWith('/')) {
      rest = rest.substring(0, rest.length - 1);
    }
    if (rest.isEmpty) return '/mnt/$drive';
    return '/mnt/$drive/$rest';
  }

  // Already a WSL-style path or other form: normalize separators only.
  var unix = trimmed.replaceAll('\\', '/');
  if (unix.length >= 2 && unix[1] == ':') {
    final drive = unix[0].toLowerCase();
    var rest = unix.length > 2 ? unix.substring(2) : '';
    while (rest.startsWith('/')) {
      rest = rest.substring(1);
    }
    if (rest.endsWith('/')) {
      rest = rest.substring(0, rest.length - 1);
    }
    if (rest.isEmpty) return '/mnt/$drive';
    return '/mnt/$drive/$rest';
  }
  return unix;
}

/// Decode WSL CLI stdout which is typically UTF-16LE (often with BOM).
String decodeWslOutput(List<int> bytes) {
  if (bytes.isEmpty) return '';

  var offset = 0;
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    offset = 2;
  } else if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    // UTF-16BE BOM — uncommon for WSL, still handle.
    final units = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      units.add((bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units).replaceAll('\u0000', '');
  }

  if (_looksLikeUtf16Le(bytes, offset)) {
    final units = <int>[];
    for (var i = offset; i + 1 < bytes.length; i += 2) {
      units.add(bytes[i] | (bytes[i + 1] << 8));
    }
    // Odd trailing byte
    if ((bytes.length - offset).isOdd) {
      units.add(bytes.last);
    }
    return String.fromCharCodes(units).replaceAll('\u0000', '');
  }

  return utf8.decode(bytes, allowMalformed: true).replaceAll('\u0000', '');
}

bool _looksLikeUtf16Le(List<int> bytes, int offset) {
  final remaining = bytes.length - offset;
  if (remaining < 4) {
    // Short ASCII via UTF-16LE: 'A\x00'
    if (remaining >= 2 && bytes[offset + 1] == 0) return true;
    return false;
  }
  var nulHigh = 0;
  var pairs = 0;
  for (var i = offset; i + 1 < bytes.length && pairs < 32; i += 2) {
    pairs++;
    if (bytes[i + 1] == 0) nulHigh++;
  }
  return pairs > 0 && nulHigh >= (pairs / 2).ceil();
}

/// Parse `wsl -l -q` (or similar) stdout into distro names.
@visibleForTesting
List<String> parseWslDistroList(String text) {
  final distros = <String>[];
  for (final line in text.split(RegExp(r'\r?\n'))) {
    var name = line.trim();
    if (name.isEmpty) continue;
    if (name.startsWith('*')) {
      name = name.substring(1).trim();
    }
    final lower = name.toLowerCase();
    if (lower.startsWith('windows subsystem')) continue;
    if (lower.startsWith('wsl ')) continue;
    // Drop parenthetical state suffixes from non-quiet listings.
    final paren = name.indexOf('(');
    if (paren > 0) {
      name = name.substring(0, paren).trim();
    }
    if (name.isEmpty) continue;
    distros.add(name);
  }
  return distros;
}

bool listContainsCuplivoDistro(Iterable<String> distros) {
  for (final name in distros) {
    if (name.toLowerCase() == kCuplivoWslDistroName.toLowerCase()) {
      return true;
    }
  }
  return false;
}

bool _messageSuggestsReboot(String text) {
  final lower = text.toLowerCase();
  return lower.contains('restart') ||
      lower.contains('reboot') ||
      lower.contains('必须重新启动') ||
      lower.contains('需要重新启动') ||
      lower.contains('必須重新啟動');
}

Future<WslProbeResult> probeWsl() async {
  try {
    final result = await Process.run(
      'wsl.exe',
      const ['-l', '-q'],
      stdoutEncoding: null,
      stderrEncoding: null,
    );

    final stdoutBytes = _asBytes(result.stdout);
    final stderrBytes = _asBytes(result.stderr);
    final text = decodeWslOutput(stdoutBytes).trim();
    final errText = decodeWslOutput(stderrBytes).trim();
    final combined = [text, errText].where((s) => s.isNotEmpty).join('\n');

    // Exit 0/1 commonly mean the platform responded (1 = no distros).
    final responded =
        result.exitCode == 0 ||
        result.exitCode == 1 ||
        text.isNotEmpty ||
        errText.toLowerCase().contains('no installed distributions');

    if (!responded && result.exitCode != 0) {
      final detail = combined.isNotEmpty
          ? combined
          : 'WSL probe failed with exit ${result.exitCode}';
      final reboot =
          result.exitCode == kWslRebootRequiredExitCode ||
          _messageSuggestsReboot(detail);
      return WslProbeResult(
        available: false,
        platformReady: false,
        cuplivoDistroReady: false,
        anyDistroReady: false,
        detail: detail,
        rebootRecommended: reboot,
      );
    }

    final distros = parseWslDistroList(text);
    final hasCuplivo = listContainsCuplivoDistro(distros);
    final any = distros.isNotEmpty;

    if (!any) {
      final detail = combined.isNotEmpty
          ? combined
          : 'WSL is installed but no distributions are registered';
      return WslProbeResult(
        available: true,
        platformReady: true,
        cuplivoDistroReady: false,
        anyDistroReady: false,
        detail: detail,
      );
    }

    return WslProbeResult(
      available: true,
      platformReady: true,
      cuplivoDistroReady: hasCuplivo,
      anyDistroReady: true,
      detail: hasCuplivo
          ? 'WSL distro ready: $kCuplivoWslDistroName'
          : 'WSL ready; shared distro $kCuplivoWslDistroName not imported yet '
                '(found: ${distros.join(', ')})',
    );
  } on ProcessException catch (e) {
    return WslProbeResult(
      available: false,
      platformReady: false,
      cuplivoDistroReady: false,
      anyDistroReady: false,
      detail: 'WSL not available: ${e.message}',
    );
  } catch (e) {
    return WslProbeResult(
      available: false,
      platformReady: false,
      cuplivoDistroReady: false,
      anyDistroReady: false,
      detail: 'WSL probe failed: $e',
    );
  }
}

Future<bool> isCuplivoDistroRegistered() async {
  final probe = await probeWsl();
  return probe.cuplivoDistroReady;
}

/// Best-effort enable of the WSL platform (no default distro download).
///
/// Prefers an elevated `wsl --install --no-distribution --no-launch` via
/// PowerShell UAC. Falls back to a direct non-elevated invoke.
/// Timeout defaults to 10 minutes.
Future<WslEnableResult> tryEnableWslPlatform({
  Duration timeout = const Duration(minutes: 10),
}) async {
  // Option A: elevated install.
  try {
    final elevated = await Process.run(
      'powershell.exe',
      const [
        '-NoProfile',
        '-Command',
        "Start-Process -FilePath 'wsl.exe' "
            "-ArgumentList '--install','--no-distribution','--no-launch' "
            '-Verb RunAs -Wait -PassThru | '
            'Select-Object -ExpandProperty ExitCode',
      ],
      stdoutEncoding: null,
      stderrEncoding: null,
    ).timeout(timeout);

    final out = decodeWslOutput(_asBytes(elevated.stdout)).trim();
    final err = decodeWslOutput(_asBytes(elevated.stderr)).trim();
    final combined = [out, err].where((s) => s.isNotEmpty).join('\n');
    final parsedExit = int.tryParse(out.split(RegExp(r'\s+')).last);
    final exitCode = parsedExit ?? elevated.exitCode;
    final reboot =
        exitCode == kWslRebootRequiredExitCode ||
        _messageSuggestsReboot(combined);

    if (exitCode == 0) {
      return WslEnableResult(
        ok: true,
        rebootRecommended: reboot,
        detail: combined.isNotEmpty
            ? combined
            : 'WSL platform enable succeeded',
        exitCode: exitCode,
      );
    }
    if (reboot) {
      return WslEnableResult(
        ok: false,
        rebootRecommended: true,
        detail: combined.isNotEmpty
            ? combined
            : 'WSL platform enable requires a system restart '
                  '(exit $exitCode)',
        exitCode: exitCode,
      );
    }

    // Elevated path failed without reboot signal — try direct invoke.
    debugPrint(
      'tryEnableWslPlatform: elevated install exit=$exitCode detail=$combined',
    );
  } on TimeoutException {
    return const WslEnableResult(
      ok: false,
      detail: 'WSL platform enable timed out after 10 minutes',
    );
  } catch (e, st) {
    debugPrint('tryEnableWslPlatform: elevated path failed: $e\n$st');
  }

  // Option B: direct (may fail without admin).
  try {
    final direct = await Process.run(
      'wsl.exe',
      const ['--install', '--no-distribution', '--no-launch'],
      stdoutEncoding: null,
      stderrEncoding: null,
    ).timeout(timeout);

    final out = decodeWslOutput(_asBytes(direct.stdout)).trim();
    final err = decodeWslOutput(_asBytes(direct.stderr)).trim();
    final combined = [out, err].where((s) => s.isNotEmpty).join('\n');
    final exitCode = direct.exitCode;
    final reboot =
        exitCode == kWslRebootRequiredExitCode ||
        _messageSuggestsReboot(combined);

    if (exitCode == 0) {
      return WslEnableResult(
        ok: true,
        rebootRecommended: reboot,
        detail: combined.isNotEmpty
            ? combined
            : 'WSL platform enable succeeded',
        exitCode: exitCode,
      );
    }
    return WslEnableResult(
      ok: false,
      rebootRecommended: reboot,
      detail: combined.isNotEmpty
          ? combined
          : 'WSL platform enable failed (exit $exitCode)',
      exitCode: exitCode,
    );
  } on TimeoutException {
    return const WslEnableResult(
      ok: false,
      detail: 'WSL platform enable timed out after 10 minutes',
    );
  } catch (e) {
    return WslEnableResult(ok: false, detail: 'WSL platform enable failed: $e');
  }
}

/// Process-wide lock so concurrent sandbox installs cannot corrupt the shared
/// VHD / race `wsl --import`.
Future<void> _cuplivoDistroLock = Future<void>.value();

Future<T> _withCuplivoDistroLock<T>(Future<T> Function() action) {
  final previous = _cuplivoDistroLock;
  final gate = Completer<void>();
  _cuplivoDistroLock = gate.future;
  return previous
      .catchError((Object _, StackTrace __) {})
      .then((_) => action())
      .whenComplete(() {
        if (!gate.isCompleted) gate.complete();
      });
}

/// Unregister shared distro (best-effort). Used before re-import of a broken
/// registration.
Future<void> unregisterCuplivoDistro() async {
  try {
    final result = await Process.run(
      'wsl.exe',
      const ['--unregister', kCuplivoWslDistroName],
      stdoutEncoding: null,
      stderrEncoding: null,
    ).timeout(const Duration(minutes: 5));
    if (result.exitCode != 0) {
      final detail = [
        decodeWslOutput(_asBytes(result.stdout)).trim(),
        decodeWslOutput(_asBytes(result.stderr)).trim(),
      ].where((s) => s.isNotEmpty).join('\n');
      debugPrint('unregisterCuplivoDistro: exit=${result.exitCode} $detail');
    }
  } catch (e, st) {
    debugPrint('unregisterCuplivoDistro failed: $e\n$st');
  }
}

/// Import [kCuplivoWslDistroName] from a rootfs tar (not tar.gz).
///
/// [installDir] must be an empty directory for the VHD. [rootfsTarPath] should
/// be a plain `.tar` of the root filesystem. Serialized process-wide.
Future<void> ensureCuplivoDistroImported({
  required String installDir,
  required String rootfsTarPath,
  void Function(double?, String)? onProgress,
}) {
  return _withCuplivoDistroLock(() async {
    final install = Directory(installDir);
    if (!await install.exists()) {
      await install.create(recursive: true);
    }
    final tar = File(rootfsTarPath);
    if (!await tar.exists()) {
      throw StateError('Rootfs tar not found: $rootfsTarPath');
    }

    // If already registered and healthy, skip import.
    if (await isCuplivoDistroRegistered() && await verifyCuplivoDistro()) {
      onProgress?.call(1.0, 'wsl_ready');
      return;
    }
    // Broken registration must be cleared before re-import.
    if (await isCuplivoDistroRegistered()) {
      onProgress?.call(0.02, 'wsl_unregister');
      await unregisterCuplivoDistro();
    }

    onProgress?.call(0.05, 'wsl_set_default_version');
    try {
      final ver = await Process.run(
        'wsl.exe',
        const ['--set-default-version', '2'],
        stdoutEncoding: null,
        stderrEncoding: null,
      ).timeout(const Duration(minutes: 2));
      if (ver.exitCode != 0) {
        final detail = [
          decodeWslOutput(_asBytes(ver.stdout)).trim(),
          decodeWslOutput(_asBytes(ver.stderr)).trim(),
        ].where((s) => s.isNotEmpty).join('\n');
        debugPrint(
          'ensureCuplivoDistroImported: set-default-version 2 '
          'exit=${ver.exitCode} $detail',
        );
      }
    } catch (e, st) {
      debugPrint(
        'ensureCuplivoDistroImported: set-default-version best-effort failed: '
        '$e\n$st',
      );
    }

    onProgress?.call(0.2, 'wsl_import');
    final importResult = await Process.run(
      'wsl.exe',
      [
        '--import',
        kCuplivoWslDistroName,
        installDir,
        rootfsTarPath,
        '--version',
        '2',
      ],
      stdoutEncoding: null,
      stderrEncoding: null,
    ).timeout(const Duration(minutes: 15));

    final importOut = [
      decodeWslOutput(_asBytes(importResult.stdout)).trim(),
      decodeWslOutput(_asBytes(importResult.stderr)).trim(),
    ].where((s) => s.isNotEmpty).join('\n');

    if (importResult.exitCode != 0) {
      throw StateError(
        'wsl --import $kCuplivoWslDistroName failed '
        '(exit ${importResult.exitCode}): '
        '${importOut.isNotEmpty ? importOut : 'no output'}',
      );
    }

    onProgress?.call(0.85, 'wsl_verify');
    final ok = await verifyCuplivoDistro();
    if (!ok) {
      throw StateError(
        'WSL distro $kCuplivoWslDistroName imported but verification failed',
      );
    }
    onProgress?.call(1.0, 'wsl_ready');
  });
}

/// Runs `wsl -d Cuplivo-Sandbox -- echo ok` and checks stdout.
Future<bool> verifyCuplivoDistro() async {
  try {
    final result = await Process.run(
      'wsl.exe',
      const ['-d', kCuplivoWslDistroName, '--', 'echo', 'ok'],
      stdoutEncoding: null,
      stderrEncoding: null,
    ).timeout(const Duration(seconds: 60));
    final out = decodeWslOutput(_asBytes(result.stdout)).trim();
    final err = decodeWslOutput(_asBytes(result.stderr)).trim();
    if (result.exitCode != 0) {
      debugPrint(
        'verifyCuplivoDistro: exit=${result.exitCode} out=$out err=$err',
      );
      return false;
    }
    return out.contains('ok');
  } catch (e, st) {
    debugPrint('verifyCuplivoDistro failed: $e\n$st');
    return false;
  }
}

Future<SandboxToolResult> execWslShell({
  required String hostFilesDir,
  required String command,
  Duration? timeout,
  String? distro,
}) async {
  final trimmed = command.trim();
  if (trimmed.isEmpty) {
    return SandboxToolResult.failure(
      'empty_command',
      'command must not be empty',
    );
  }

  var effective = timeout ?? const Duration(seconds: 30);
  if (effective > const Duration(seconds: 120)) {
    effective = const Duration(seconds: 120);
  }
  if (effective.isNegative || effective == Duration.zero) {
    effective = const Duration(seconds: 30);
  }

  final effectiveDistro = (distro != null && distro.trim().isNotEmpty)
      ? distro.trim()
      : kCuplivoWslDistroName;

  final wslCd = hostPathToWsl(hostFilesDir);
  final args = <String>[
    '-d',
    effectiveDistro,
    // Prefer --cd; also pass bash -lc so the user command runs in a login shell.
    '--cd',
    wslCd,
    '--',
    'bash',
    '-lc',
    trimmed,
  ];

  try {
    final process = await Process.start('wsl.exe', args, runInShell: false);

    const maxOutputBytes = 256 * 1024;
    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    var truncated = false;
    var total = 0;

    void take(List<int> chunk, BytesBuilder sink) {
      if (truncated) return;
      final remaining = maxOutputBytes - total;
      if (remaining <= 0) {
        truncated = true;
        return;
      }
      if (chunk.length <= remaining) {
        sink.add(chunk);
        total += chunk.length;
      } else {
        sink.add(chunk.sublist(0, remaining));
        total += remaining;
        truncated = true;
      }
    }

    final stdoutSub = process.stdout.listen((c) => take(c, out));
    final stderrSub = process.stderr.listen((c) => take(c, err));

    var timedOut = false;
    final exitCode = await process.exitCode.timeout(
      effective,
      onTimeout: () async {
        timedOut = true;
        process.kill(ProcessSignal.sigkill);
        try {
          return await process.exitCode.timeout(const Duration(seconds: 2));
        } catch (e, st) {
          debugPrint('execWslShell: kill wait failed: $e\n$st');
          return -1;
        }
      },
    );

    await stdoutSub.cancel();
    await stderrSub.cancel();

    final stdoutText = utf8.decode(out.takeBytes(), allowMalformed: true);
    final stderrText = utf8.decode(err.takeBytes(), allowMalformed: true);
    final buf = StringBuffer();
    if (stdoutText.isNotEmpty) buf.write(stdoutText);
    if (stderrText.isNotEmpty) {
      if (buf.isNotEmpty && !buf.toString().endsWith('\n')) buf.writeln();
      buf.write(stderrText);
    }
    if (timedOut) {
      return SandboxToolResult.failure(
        'timeout',
        'Command timed out after ${effective.inSeconds}s',
        exitCode: exitCode,
        timedOut: true,
      );
    }
    return SandboxToolResult.success(
      buf.toString(),
      exitCode: exitCode,
      outputTruncated: truncated,
    );
  } catch (e) {
    return SandboxToolResult.failure('shell_error', e.toString());
  }
}

List<int> _asBytes(Object? value) {
  if (value == null) return const <int>[];
  if (value is List<int>) return value;
  if (value is Uint8List) return value;
  if (value is String) return utf8.encode(value);
  return utf8.encode(value.toString());
}
