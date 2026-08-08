import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../utils/app_directories.dart';
import '../models/linux_sandbox.dart';
import 'local_jail_fs.dart';
import 'sandbox_disk_layout.dart';
import 'sandbox_runtime.dart';
import 'windows_wsl.dart';
import 'wsl_rootfs_installer.dart';

/// Windows sandbox runtime: real Linux via shared WSL distro only.
///
/// File tools use [LocalJailFs] on the host `files/` tree. Shell always goes
/// through `wsl.exe -d Cuplivo-Sandbox`. There is no localJail shell fallback.
class WindowsSandboxRuntime implements SandboxRuntime {
  WindowsSandboxRuntime(this.sandboxId);

  LinuxSandboxRuntimeMode _mode = LinuxSandboxRuntimeMode.wsl;

  @override
  final String sandboxId;

  @override
  bool get isSupported => true;

  @override
  LinuxSandboxRuntimeMode get runtimeMode => _mode;

  Future<LocalJailFs> _fs() async {
    await ensureReady();
    final files = await SandboxDiskLayout.filesDir(sandboxId);
    return LocalJailFs(files);
  }

  Future<void> _refreshModeFromDisk() async {
    final name = await SandboxDiskLayout.readRuntimeMode(sandboxId);
    if (name == null) return;
    for (final e in LinuxSandboxRuntimeMode.values) {
      if (e.name == name) {
        _mode = e;
        return;
      }
    }
  }

  Future<Directory> _sharedDistroInstallDir() async {
    final base = await AppDirectories.getWslDistrosDirectory();
    return Directory(p.join(base.path, kCuplivoWslDistroName));
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
      onProgress?.call(0.02, 'layout');
      await ensureReady();

      onProgress?.call(0.08, 'probe_wsl');
      var probe = await probeWsl();
      if (probe.cuplivoDistroReady) {
        final verified = await verifyCuplivoDistro();
        if (verified) {
          return _markWslReady(onProgress: onProgress);
        }
        debugPrint(
          'WindowsSandboxRuntime: Cuplivo distro registered but verify failed; '
          'will re-import if possible',
        );
      }

      if (!probe.platformReady) {
        onProgress?.call(0.15, 'enable_wsl');
        final enable = await tryEnableWslPlatform();
        if (enable.rebootRecommended) {
          return SandboxInstallResult.failure(
            LinuxSandboxRuntimeMode.wsl,
            enable.detail ??
                'Restart Windows, then tap Install base environment again.',
            errorCode: 'wsl_reboot_required',
          );
        }
        if (!enable.ok) {
          return SandboxInstallResult.failure(
            LinuxSandboxRuntimeMode.wsl,
            enable.detail ??
                'Could not enable the WSL platform. Grant admin permission '
                    'or install WSL, then retry.',
            errorCode: 'wsl_enable_failed',
          );
        }

        onProgress?.call(0.25, 'probe_wsl');
        probe = await probeWsl();
        if (probe.rebootRecommended) {
          return SandboxInstallResult.failure(
            LinuxSandboxRuntimeMode.wsl,
            probe.detail ??
                'Restart Windows, then tap Install base environment again.',
            errorCode: 'wsl_reboot_required',
          );
        }
        if (!probe.platformReady) {
          return SandboxInstallResult.failure(
            LinuxSandboxRuntimeMode.wsl,
            probe.detail ??
                'WSL platform is still not ready after enable attempt.',
            errorCode: 'wsl_enable_failed',
          );
        }
      }

      if (probe.cuplivoDistroReady) {
        final verified = await verifyCuplivoDistro();
        if (verified) {
          return _markWslReady(onProgress: onProgress);
        }
      }

      // Download rootfs + import shared distro (process-wide lock inside
      // ensureCuplivoDistroImported). Broken registrations are unregistered
      // there before re-import.
      final tmp = await SandboxDiskLayout.tmpDir(sandboxId);
      final installDir = await _sharedDistroInstallDir();
      if (probe.cuplivoDistroReady) {
        // verify failed above — force clean re-import path
        onProgress?.call(0.28, 'wsl_unregister');
        await unregisterCuplivoDistro();
      }
      if (await installDir.exists()) {
        try {
          await installDir.delete(recursive: true);
        } catch (e, st) {
          debugPrint(
            'WindowsSandboxRuntime: clear stale WSL install dir failed: $e\n$st',
          );
        }
      }
      await installDir.create(recursive: true);

      final installer = WslRootfsInstaller();
      late final String tarPath;
      try {
        onProgress?.call(0.30, 'download');
        tarPath = await installer.downloadAndGunzipTar(
          tmpDir: tmp.path,
          onProgress: (progress, stage) {
            // Map download/gunzip into 0.30..0.75
            final mapped = 0.30 + ((progress ?? 0).clamp(0.0, 1.0) * 0.45);
            onProgress?.call(mapped, stage);
          },
        );

        onProgress?.call(0.78, 'import');
        await ensureCuplivoDistroImported(
          installDir: installDir.path,
          rootfsTarPath: tarPath,
          onProgress: (progress, stage) {
            final mapped = 0.78 + ((progress ?? 0).clamp(0.0, 1.0) * 0.18);
            onProgress?.call(mapped, stage);
          },
        );
      } finally {
        installer.close();
        try {
          final tar = File(p.join(tmp.path, 'rootfs.tar'));
          if (await tar.exists()) await tar.delete();
        } catch (e, st) {
          debugPrint(
            'WindowsSandboxRuntime: cleanup rootfs.tar failed: $e\n$st',
          );
        }
        try {
          final gz = File(p.join(tmp.path, 'rootfs.tar.gz'));
          if (await gz.exists()) await gz.delete();
        } catch (e, st) {
          debugPrint(
            'WindowsSandboxRuntime: cleanup rootfs.tar.gz failed: $e\n$st',
          );
        }
      }

      return _markWslReady(onProgress: onProgress);
    } catch (e, st) {
      debugPrint('WindowsSandboxRuntime.installBaseEnv failed: $e\n$st');
      return SandboxInstallResult.failure(
        LinuxSandboxRuntimeMode.wsl,
        e.toString(),
      );
    }
  }

  Future<SandboxInstallResult> _markWslReady({
    void Function(double? progress, String stage)? onProgress,
  }) async {
    onProgress?.call(0.95, 'marker');
    await SandboxDiskLayout.writeRuntimeMode(
      sandboxId,
      LinuxSandboxRuntimeMode.wsl.name,
    );
    await SandboxDiskLayout.writeBaseEnvMarker(sandboxId);
    _mode = LinuxSandboxRuntimeMode.wsl;
    onProgress?.call(1.0, 'done');
    return SandboxInstallResult.success(LinuxSandboxRuntimeMode.wsl);
  }

  @override
  Future<LinuxSandboxStatus> probeStatus() async {
    try {
      await _refreshModeFromDisk();
      final root = await SandboxDiskLayout.sandboxRoot(sandboxId);
      if (!await root.exists()) return LinuxSandboxStatus.notReady;
      final files = await SandboxDiskLayout.filesDir(sandboxId);
      if (!await files.exists()) return LinuxSandboxStatus.notReady;

      final hasMarker = await SandboxDiskLayout.hasBaseEnvMarker(sandboxId);
      if (!hasMarker) return LinuxSandboxStatus.notReady;

      final probe = await probeWsl();
      if (probe.cuplivoDistroReady) {
        final verified = await verifyCuplivoDistro();
        if (verified) {
          _mode = LinuxSandboxRuntimeMode.wsl;
          return LinuxSandboxStatus.ready;
        }
        debugPrint(
          'WindowsSandboxRuntime.probeStatus: marker present but '
          'Cuplivo-Sandbox verify failed',
        );
        return LinuxSandboxStatus.broken;
      }
      debugPrint(
        'WindowsSandboxRuntime.probeStatus: marker present but '
        'Cuplivo-Sandbox missing (${probe.detail})',
      );
      return LinuxSandboxStatus.broken;
    } catch (e, st) {
      debugPrint('WindowsSandboxRuntime.probeStatus failed: $e\n$st');
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
    await ensureReady();
    await _refreshModeFromDisk();

    final hasMarker = await SandboxDiskLayout.hasBaseEnvMarker(sandboxId);
    if (!hasMarker || _mode != LinuxSandboxRuntimeMode.wsl) {
      return SandboxToolResult.failure(
        'sandbox_not_ready',
        'Sandbox base environment is not ready. Install WSL base env first.',
      );
    }

    final probe = await probeWsl();
    if (!probe.cuplivoDistroReady) {
      return SandboxToolResult.failure(
        'wsl_unavailable',
        probe.detail ??
            'WSL distro $kCuplivoWslDistroName is not available. '
                'Reinstall the base environment.',
      );
    }

    final files = await rootDirectory();
    return execWslShell(
      hostFilesDir: files.path,
      command: command,
      timeout: timeout,
      distro: kCuplivoWslDistroName,
    );
  }

  @override
  Future<List<SandboxFsEntry>> listDir([String path = '']) async {
    final fs = await _fs();
    return fs.listDir(path);
  }

  /// Destroys only this sandbox tree. Does **not** unregister the shared
  /// [kCuplivoWslDistroName] distro (shared across sandboxes).
  @override
  Future<void> destroyDisk() => SandboxDiskLayout.destroySandboxTree(sandboxId);
}
