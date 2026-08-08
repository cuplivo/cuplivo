import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/linux_sandbox.dart';
import 'local_jail_fs.dart';
import 'sandbox_disk_layout.dart';
import 'sandbox_runtime.dart';

/// Native Linux desktop runtime: file jail under `files/`, shell via `/bin/sh -c`.
class NativeLinuxSandboxRuntime implements SandboxRuntime {
  NativeLinuxSandboxRuntime(this.sandboxId);

  static const Duration defaultShellTimeout = Duration(seconds: 30);
  static const Duration maxShellTimeout = Duration(seconds: 120);
  static const int maxOutputBytes = 256 * 1024;

  @override
  final String sandboxId;

  @override
  bool get isSupported => true;

  @override
  LinuxSandboxRuntimeMode get runtimeMode =>
      LinuxSandboxRuntimeMode.nativeLinux;

  Future<LocalJailFs> _fs() async {
    await ensureReady();
    final files = await SandboxDiskLayout.filesDir(sandboxId);
    return LocalJailFs(files);
  }

  @override
  Future<Directory> rootDirectory() => SandboxDiskLayout.filesDir(sandboxId);

  @override
  Future<void> ensureReady() => SandboxDiskLayout.ensureLayout(sandboxId);

  @override
  Future<SandboxInstallResult> installBaseEnv({
    void Function(double? progress, String stage)? onProgress,
  }) async {
    try {
      onProgress?.call(0.1, 'layout');
      await ensureReady();
      onProgress?.call(0.8, 'marker');
      await SandboxDiskLayout.writeBaseEnvMarker(sandboxId);
      onProgress?.call(1.0, 'done');
      return SandboxInstallResult.success(runtimeMode);
    } catch (e) {
      return SandboxInstallResult.failure(runtimeMode, e.toString());
    }
  }

  @override
  Future<LinuxSandboxStatus> probeStatus() async {
    try {
      final root = await SandboxDiskLayout.sandboxRoot(sandboxId);
      if (!await root.exists()) return LinuxSandboxStatus.notReady;
      final files = await SandboxDiskLayout.filesDir(sandboxId);
      if (!await files.exists()) return LinuxSandboxStatus.notReady;
      if (await SandboxDiskLayout.hasBaseEnvMarker(sandboxId)) {
        return LinuxSandboxStatus.ready;
      }
      return LinuxSandboxStatus.notReady;
    } catch (_) {
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
      final files = await rootDirectory();
      final process = await Process.start(
        '/bin/sh',
        ['-c', trimmed],
        workingDirectory: files.path,
        runInShell: false,
      );

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
          } catch (_) {
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

  @override
  Future<List<SandboxFsEntry>> listDir([String path = '']) async {
    final fs = await _fs();
    return fs.listDir(path);
  }

  @override
  Future<void> destroyDisk() => SandboxDiskLayout.destroySandboxTree(sandboxId);
}
