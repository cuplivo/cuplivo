import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../utils/app_directories.dart';

/// On-disk layout for a single Linux Sandbox under app data:
/// `{appData}/linux_sandboxes/<id>/{files,linux,tmp}/`.
class SandboxDiskLayout {
  SandboxDiskLayout._();

  static const String filesDirName = 'files';
  static const String linuxDirName = 'linux';
  static const String tmpDirName = 'tmp';
  static const String baseEnvMarkerName = '.base_env_ready';
  static const String runtimeModeMarkerName = '.runtime_mode';

  static const Set<String> reservedNames = {
    filesDirName,
    linuxDirName,
    tmpDirName,
    baseEnvMarkerName,
    runtimeModeMarkerName,
  };

  /// Reject empty ids and path-escape segments so disk ops cannot leave
  /// the sandboxes base directory.
  static bool isValidSandboxId(String id) {
    final trimmed = id.trim();
    if (trimmed.isEmpty || trimmed != id) return false;
    if (trimmed == '.' || trimmed == '..') return false;
    if (trimmed.contains('/') ||
        trimmed.contains('\\') ||
        trimmed.contains('\u0000')) {
      return false;
    }
    if (trimmed.contains('..')) return false;
    return true;
  }

  static void _requireValidId(String id) {
    if (!isValidSandboxId(id)) {
      throw ArgumentError.value(id, 'id', 'Invalid sandbox id');
    }
  }

  static Future<Directory> sandboxesBase() =>
      AppDirectories.getLinuxSandboxesDirectory();

  static Future<Directory> sandboxRoot(String id) async {
    _requireValidId(id);
    final base = await sandboxesBase();
    return Directory(p.join(base.path, id));
  }

  static Future<Directory> filesDir(String id) async {
    final root = await sandboxRoot(id);
    return Directory(p.join(root.path, filesDirName));
  }

  static Future<Directory> linuxDir(String id) async {
    final root = await sandboxRoot(id);
    return Directory(p.join(root.path, linuxDirName));
  }

  static Future<Directory> tmpDir(String id) async {
    final root = await sandboxRoot(id);
    return Directory(p.join(root.path, tmpDirName));
  }

  static Future<File> baseEnvMarkerFile(String id) async {
    final root = await sandboxRoot(id);
    return File(p.join(root.path, baseEnvMarkerName));
  }

  static Future<File> runtimeModeMarkerFile(String id) async {
    final root = await sandboxRoot(id);
    return File(p.join(root.path, runtimeModeMarkerName));
  }

  /// Create `{files,linux,tmp}/` and migrate a v1 flat root into `files/`.
  static Future<void> ensureLayout(String id) async {
    final root = await sandboxRoot(id);
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    await _migrateV1FlatIfNeeded(root);
    for (final name in [filesDirName, linuxDirName, tmpDirName]) {
      final dir = Directory(p.join(root.path, name));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    }
  }

  static Future<bool> hasBaseEnvMarker(String id) async {
    final marker = await baseEnvMarkerFile(id);
    return marker.exists();
  }

  static Future<void> writeBaseEnvMarker(String id) async {
    await ensureLayout(id);
    final marker = await baseEnvMarkerFile(id);
    await marker.writeAsString(
      'ready\n${DateTime.now().toUtc().toIso8601String()}\n',
      flush: true,
    );
  }

  /// Persists runtime mode name (`wsl`, `localJail`, …) under the sandbox root.
  static Future<void> writeRuntimeMode(String id, String modeName) async {
    await ensureLayout(id);
    final marker = await runtimeModeMarkerFile(id);
    await marker.writeAsString('${modeName.trim()}\n', flush: true);
  }

  static Future<String?> readRuntimeMode(String id) async {
    final marker = await runtimeModeMarkerFile(id);
    if (!await marker.exists()) return null;
    final raw = (await marker.readAsString()).trim();
    if (raw.isEmpty) return null;
    return raw;
  }

  static Future<void> destroySandboxTree(String id) async {
    _requireValidId(id);
    final root = await sandboxRoot(id);
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  }

  /// v1 stored user files directly under `<id>/`. Move non-reserved entries
  /// into `<id>/files/` when `files/` is missing.
  static Future<void> _migrateV1FlatIfNeeded(Directory root) async {
    final files = Directory(p.join(root.path, filesDirName));
    if (await files.exists()) return;

    final children = <FileSystemEntity>[];
    await for (final entity in root.list(followLinks: false)) {
      children.add(entity);
    }
    if (children.isEmpty) return;

    final toMove = <FileSystemEntity>[];
    for (final entity in children) {
      final name = p.basename(entity.path);
      if (reservedNames.contains(name)) continue;
      toMove.add(entity);
    }
    if (toMove.isEmpty) return;

    await files.create(recursive: true);
    for (final entity in toMove) {
      final name = p.basename(entity.path);
      final dest = p.join(files.path, name);
      try {
        await entity.rename(dest);
      } catch (_) {
        // Cross-device rename can fail; fall back to copy+delete.
        if (entity is File) {
          await entity.copy(dest);
          await entity.delete();
        } else if (entity is Directory) {
          await _copyDirectory(entity, Directory(dest));
          await entity.delete(recursive: true);
        } else if (entity is Link) {
          final target = await entity.target();
          await Link(dest).create(target);
          await entity.delete();
        }
      }
    }
  }

  static Future<void> _copyDirectory(Directory src, Directory dest) async {
    await dest.create(recursive: true);
    await for (final entity in src.list(recursive: false, followLinks: false)) {
      final name = p.basename(entity.path);
      final targetPath = p.join(dest.path, name);
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(targetPath));
      } else if (entity is File) {
        await entity.copy(targetPath);
      } else if (entity is Link) {
        final target = await entity.target();
        await Link(targetPath).create(target);
      }
    }
  }
}
