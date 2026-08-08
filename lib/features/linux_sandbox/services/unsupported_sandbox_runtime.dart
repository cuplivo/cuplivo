import 'dart:io';

import '../models/linux_sandbox.dart';
import 'local_jail_fs.dart';
import 'sandbox_disk_layout.dart';
import 'sandbox_runtime.dart';

class UnsupportedSandboxRuntime implements SandboxRuntime {
  UnsupportedSandboxRuntime(this.sandboxId);

  @override
  final String sandboxId;

  @override
  bool get isSupported => false;

  @override
  LinuxSandboxRuntimeMode get runtimeMode =>
      LinuxSandboxRuntimeMode.unsupported;

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
    return SandboxInstallResult.failure(
      runtimeMode,
      'Linux Sandbox base env is not supported on this platform',
    );
  }

  @override
  Future<LinuxSandboxStatus> probeStatus() async {
    return LinuxSandboxStatus.disabled;
  }

  SandboxToolResult _unsupported() {
    return SandboxToolResult.failure(
      'platform_unsupported',
      'Linux Sandbox tools are not supported on this platform',
    );
  }

  @override
  Future<SandboxToolResult> read(String path) async => _unsupported();

  @override
  Future<SandboxToolResult> write(String path, String content) async =>
      _unsupported();

  @override
  Future<SandboxToolResult> edit(
    String path,
    String oldString,
    String newString,
  ) async => _unsupported();

  @override
  Future<SandboxToolResult> shell(String command, {Duration? timeout}) async =>
      _unsupported();

  @override
  Future<List<SandboxFsEntry>> listDir([String path = '']) async {
    final fs = await _fs();
    return fs.listDir(path);
  }

  @override
  Future<void> destroyDisk() => SandboxDiskLayout.destroySandboxTree(sandboxId);
}
