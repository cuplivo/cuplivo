import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/linux_sandbox.dart';
import 'android_linux_sandbox_channel.dart';
import 'android_rootfs_installer.dart';
import 'android_rootfs_urls.dart';
import 'local_jail_fs.dart';
import 'sandbox_disk_layout.dart';
import 'sandbox_runtime.dart';

/// Android PRoot runtime: file jail under `files/`, shell via native proot.
///
/// Convenience isolation only — not a security boundary. Network remains
/// unrestricted residual risk.
class AndroidProotSandboxRuntime implements SandboxRuntime {
  AndroidProotSandboxRuntime(
    this.sandboxId, {
    AndroidLinuxSandboxChannel? channel,
    AndroidRootfsInstaller? installer,
  }) : _channel = channel ?? AndroidLinuxSandboxChannel(),
       _installer = installer,
       _ownsInstaller = installer == null;

  static const Duration defaultShellTimeout = Duration(seconds: 30);
  static const Duration maxShellTimeout = Duration(seconds: 120);

  @override
  final String sandboxId;

  final AndroidLinuxSandboxChannel _channel;
  final AndroidRootfsInstaller? _installer;
  final bool _ownsInstaller;

  @override
  bool get isSupported => true;

  @override
  LinuxSandboxRuntimeMode get runtimeMode => LinuxSandboxRuntimeMode.proot;

  Future<LocalJailFs> _fs() async {
    await ensureReady();
    final files = await SandboxDiskLayout.filesDir(sandboxId);
    return LocalJailFs(files);
  }

  AndroidRootfsInstaller _obtainInstaller() {
    return _installer ?? AndroidRootfsInstaller();
  }

  @override
  Future<Directory> rootDirectory() => SandboxDiskLayout.filesDir(sandboxId);

  @override
  Future<void> ensureReady() => SandboxDiskLayout.ensureLayout(sandboxId);

  @override
  Future<SandboxInstallResult> installBaseEnv({
    void Function(double? progress, String stage)? onProgress,
  }) async {
    final installer = _obtainInstaller();
    try {
      onProgress?.call(0.01, 'layout');
      await ensureReady();

      final abi = await _channel.getSupportedAbi();
      final url = AndroidRootfsUrls.urlForAbi(abi);
      if (url == null) {
        return SandboxInstallResult.failure(
          runtimeMode,
          'Unsupported Android ABI for PRoot sandbox: $abi',
        );
      }

      final root = await SandboxDiskLayout.sandboxRoot(sandboxId);
      await installer.install(
        sandboxRoot: root.path,
        url: url,
        onProgress: onProgress,
      );

      onProgress?.call(0.995, 'marker');
      await SandboxDiskLayout.writeBaseEnvMarker(sandboxId);
      onProgress?.call(1.0, 'done');
      return SandboxInstallResult.success(runtimeMode);
    } catch (e, st) {
      debugPrint('AndroidProotSandboxRuntime.installBaseEnv: $e\n$st');
      return SandboxInstallResult.failure(runtimeMode, e.toString());
    } finally {
      if (_ownsInstaller && installer != _installer) {
        installer.close();
      }
    }
  }

  @override
  Future<LinuxSandboxStatus> probeStatus() async {
    try {
      final root = await SandboxDiskLayout.sandboxRoot(sandboxId);
      if (!await root.exists()) return LinuxSandboxStatus.notReady;
      final files = await SandboxDiskLayout.filesDir(sandboxId);
      if (!await files.exists()) return LinuxSandboxStatus.notReady;

      final linux = await SandboxDiskLayout.linuxDir(sandboxId);
      final sh = File('${linux.path}/bin/sh');
      final hasMarker = await SandboxDiskLayout.hasBaseEnvMarker(sandboxId);
      final hasRootfs = await sh.exists();

      if (hasRootfs && hasMarker) return LinuxSandboxStatus.ready;
      if (hasRootfs && !hasMarker) return LinuxSandboxStatus.broken;
      return LinuxSandboxStatus.notReady;
    } catch (e, st) {
      debugPrint('AndroidProotSandboxRuntime.probeStatus: $e\n$st');
      return LinuxSandboxStatus.broken;
    }
  }

  @override
  Future<SandboxToolResult> read(String path) async {
    final fs = await _fs();
    return fs.read(path);
  }

  @override
  Future<SandboxToolResult> write(String path, String content) async {
    final fs = await _fs();
    return fs.write(path, content);
  }

  @override
  Future<SandboxToolResult> edit(
    String path,
    String oldString,
    String newString,
  ) async {
    final fs = await _fs();
    return fs.edit(path, oldString, newString);
  }

  @override
  Future<SandboxToolResult> shell(String command, {Duration? timeout}) async {
    final trimmed = command.trim();
    if (trimmed.isEmpty) {
      return SandboxToolResult.failure(
        'empty_command',
        'command must not be empty',
      );
    }
    var effective = timeout ?? defaultShellTimeout;
    if (effective > maxShellTimeout) effective = maxShellTimeout;
    if (effective.isNegative || effective == Duration.zero) {
      effective = defaultShellTimeout;
    }

    try {
      await ensureReady();
      final status = await probeStatus();
      if (status != LinuxSandboxStatus.ready) {
        return SandboxToolResult.failure(
          'not_ready',
          'Sandbox base environment is not ready (status=$status)',
        );
      }

      final root = await SandboxDiskLayout.sandboxRoot(sandboxId);
      final result = await _channel.execShell(
        sandboxRoot: root.path,
        command: trimmed,
        timeoutMs: effective.inMilliseconds,
      );

      final buf = StringBuffer();
      if (result.stdout.isNotEmpty) buf.write(result.stdout);
      if (result.stderr.isNotEmpty) {
        if (buf.isNotEmpty && !buf.toString().endsWith('\n')) buf.writeln();
        buf.write(result.stderr);
      }

      if (result.timedOut) {
        return SandboxToolResult.failure(
          'timeout',
          'Command timed out after ${effective.inSeconds}s',
          exitCode: result.exitCode,
          timedOut: true,
        );
      }
      return SandboxToolResult.success(
        buf.toString(),
        exitCode: result.exitCode,
        outputTruncated: result.truncated,
      );
    } catch (e, st) {
      debugPrint('AndroidProotSandboxRuntime.shell: $e\n$st');
      return SandboxToolResult.failure('shell_error', e.toString());
    }
  }

  @override
  Future<List<SandboxFsEntry>> listDir([String path = '']) async {
    final fs = await _fs();
    return fs.listDir(path);
  }

  @override
  Future<void> destroyDisk() async {
    try {
      final root = await SandboxDiskLayout.sandboxRoot(sandboxId);
      await _channel.destroy(root.path);
    } catch (e, st) {
      debugPrint('AndroidProotSandboxRuntime.destroy channel: $e\n$st');
    }
    await SandboxDiskLayout.destroySandboxTree(sandboxId);
  }
}
