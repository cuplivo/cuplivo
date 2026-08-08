import 'dart:io';

import '../models/linux_sandbox.dart';
import 'android_proot_sandbox_runtime.dart';
import 'native_linux_sandbox_runtime.dart';
import 'unsupported_sandbox_runtime.dart';
import 'windows_sandbox_runtime.dart';

class SandboxFsEntry {
  final String name;
  final bool isDirectory;
  final int? size;
  final DateTime? modifiedAt;

  const SandboxFsEntry({
    required this.name,
    required this.isDirectory,
    this.size,
    this.modifiedAt,
  });
}

class SandboxToolResult {
  final bool ok;
  final String? content;
  final String? errorCode;
  final String? errorMessage;
  final int? exitCode;
  final bool timedOut;
  final bool outputTruncated;

  const SandboxToolResult({
    required this.ok,
    this.content,
    this.errorCode,
    this.errorMessage,
    this.exitCode,
    this.timedOut = false,
    this.outputTruncated = false,
  });

  factory SandboxToolResult.success(
    String content, {
    int? exitCode,
    bool outputTruncated = false,
  }) {
    return SandboxToolResult(
      ok: true,
      content: content,
      exitCode: exitCode,
      outputTruncated: outputTruncated,
    );
  }

  factory SandboxToolResult.failure(
    String errorCode,
    String errorMessage, {
    int? exitCode,
    bool timedOut = false,
  }) {
    return SandboxToolResult(
      ok: false,
      errorCode: errorCode,
      errorMessage: errorMessage,
      exitCode: exitCode,
      timedOut: timedOut,
    );
  }

  Map<String, dynamic> toJson() {
    if (ok) {
      return {
        'ok': true,
        'content': content ?? '',
        if (exitCode != null) 'exit_code': exitCode,
        if (outputTruncated) 'output_truncated': true,
      };
    }
    return {
      'ok': false,
      'error': errorCode ?? 'error',
      'message': errorMessage ?? 'Unknown error',
      if (exitCode != null) 'exit_code': exitCode,
      if (timedOut) 'timed_out': true,
    };
  }
}

class SandboxInstallResult {
  final bool ok;
  final LinuxSandboxRuntimeMode mode;
  final String? errorMessage;
  final String? statusMessage;

  /// Stable machine code e.g. `wsl_reboot_required`, `wsl_enable_failed`.
  final String? errorCode;

  const SandboxInstallResult({
    required this.ok,
    required this.mode,
    this.errorMessage,
    this.statusMessage,
    this.errorCode,
  });

  factory SandboxInstallResult.success(
    LinuxSandboxRuntimeMode mode, {
    String? statusMessage,
  }) {
    return SandboxInstallResult(
      ok: true,
      mode: mode,
      statusMessage: statusMessage,
    );
  }

  factory SandboxInstallResult.failure(
    LinuxSandboxRuntimeMode mode,
    String errorMessage, {
    String? errorCode,
  }) {
    return SandboxInstallResult(
      ok: false,
      mode: mode,
      errorMessage: errorMessage,
      errorCode: errorCode,
    );
  }
}

abstract class SandboxRuntime {
  String get sandboxId;

  bool get isSupported;

  LinuxSandboxRuntimeMode get runtimeMode;

  /// User workspace root (`files/`), not the sandbox tree root.
  Future<Directory> rootDirectory();

  /// Layout only: create `{files,linux,tmp}/` and migrate v1 flat trees.
  Future<void> ensureReady();

  /// Explicit base-env install (WSL import, PRoot rootfs, or local layout).
  Future<SandboxInstallResult> installBaseEnv({
    void Function(double? progress, String stage)? onProgress,
  });

  /// Integrity probe for provider status reconciliation.
  Future<LinuxSandboxStatus> probeStatus();

  Future<SandboxToolResult> read(String path);

  Future<SandboxToolResult> write(String path, String content);

  Future<SandboxToolResult> edit(
    String path,
    String oldString,
    String newString,
  );

  Future<SandboxToolResult> shell(String command, {Duration? timeout});

  Future<List<SandboxFsEntry>> listDir([String path = '']);

  Future<void> destroyDisk();
}

SandboxRuntime createSandboxRuntime(String sandboxId) {
  if (Platform.isWindows) {
    return WindowsSandboxRuntime(sandboxId);
  }
  if (Platform.isLinux) {
    return NativeLinuxSandboxRuntime(sandboxId);
  }
  if (Platform.isAndroid) {
    return AndroidProotSandboxRuntime(sandboxId);
  }
  return UnsupportedSandboxRuntime(sandboxId);
}
