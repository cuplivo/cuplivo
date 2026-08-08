import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Result of a PRoot shell invocation on Android.
class AndroidProotShellResult {
  const AndroidProotShellResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.timedOut,
    required this.truncated,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;
  final bool truncated;

  factory AndroidProotShellResult.fromMap(Map<dynamic, dynamic> map) {
    return AndroidProotShellResult(
      exitCode: (map['exitCode'] as num?)?.toInt() ?? -1,
      stdout: map['stdout']?.toString() ?? '',
      stderr: map['stderr']?.toString() ?? '',
      timedOut: map['timedOut'] == true,
      truncated: map['truncated'] == true,
    );
  }
}

/// Method channel bridge to the Cuplivo Android PRoot plugin.
class AndroidLinuxSandboxChannel {
  AndroidLinuxSandboxChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'app.linux_sandbox';

  final MethodChannel _channel;

  static String? _cachedAbi;

  Future<String> getNativeLibraryDir() async {
    final result = await _channel.invokeMethod<String>('getNativeLibraryDir');
    return result ?? '';
  }

  /// Returns `arm64-v8a`, `x86_64`, or `unsupported`.
  Future<String> getSupportedAbi() async {
    if (_cachedAbi != null) return _cachedAbi!;
    try {
      final result = await _channel.invokeMethod<String>('getSupportedAbi');
      _cachedAbi = (result == null || result.isEmpty) ? 'unsupported' : result;
    } on MissingPluginException {
      _cachedAbi = 'unsupported';
    } catch (e, st) {
      debugPrint('AndroidLinuxSandboxChannel.getSupportedAbi: $e\n$st');
      _cachedAbi = 'unsupported';
    }
    return _cachedAbi!;
  }

  Future<bool> hasRootfs(String sandboxRoot) async {
    final result = await _channel.invokeMethod<bool>('hasRootfs', {
      'sandboxRoot': sandboxRoot,
    });
    return result == true;
  }

  Future<AndroidProotShellResult> execShell({
    required String sandboxRoot,
    required String command,
    required int timeoutMs,
  }) async {
    final raw = await _channel.invokeMethod<dynamic>('execShell', {
      'sandboxRoot': sandboxRoot,
      'command': command,
      'timeoutMs': timeoutMs,
    });
    if (raw is Map) {
      return AndroidProotShellResult.fromMap(raw);
    }
    throw StateError('execShell returned unexpected payload: $raw');
  }

  Future<void> destroy(String sandboxRoot) async {
    try {
      await _channel.invokeMethod<void>('destroy', {
        'sandboxRoot': sandboxRoot,
      });
    } on MissingPluginException {
      // No-op when plugin is absent (tests / non-Android).
    }
  }

  /// Test helper to clear ABI cache between unit tests.
  @visibleForTesting
  static void clearAbiCache() {
    _cachedAbi = null;
  }
}
