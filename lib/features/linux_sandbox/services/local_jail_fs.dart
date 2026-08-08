import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'linux_sandbox_path.dart';
import 'sandbox_runtime.dart';

/// Shared host filesystem ops jailed under [jailRoot] (typically `files/`).
class LocalJailFs {
  LocalJailFs(this.jailRoot);

  static const int maxReadBytes = 1024 * 1024;

  final Directory jailRoot;

  Future<void> ensureRoot() async {
    if (!await jailRoot.exists()) {
      await jailRoot.create(recursive: true);
    }
  }

  Future<String> resolve(String guestPath) {
    return LinuxSandboxPath.resolveHostPath(
      jailRoot: jailRoot.path,
      guestPath: guestPath,
    );
  }

  Future<SandboxToolResult> read(String path) async {
    try {
      await ensureRoot();
      final hostPath = await resolve(path);
      final file = File(hostPath);
      final dir = Directory(hostPath);
      if (await file.exists()) {
        final length = await file.length();
        if (length > maxReadBytes) {
          return SandboxToolResult.failure(
            'file_too_large',
            'File exceeds $maxReadBytes byte read limit: $path',
          );
        }
        final bytes = await file.readAsBytes();
        if (_looksBinary(bytes)) {
          return SandboxToolResult.failure(
            'binary_file',
            'Binary file cannot be read as text: $path',
          );
        }
        return SandboxToolResult.success(
          utf8.decode(bytes, allowMalformed: true),
        );
      }
      if (await dir.exists()) {
        final entries = await listDir(path);
        final buf = StringBuffer();
        for (final e in entries) {
          buf.writeln(e.isDirectory ? '${e.name}/' : e.name);
        }
        return SandboxToolResult.success(buf.toString().trimRight());
      }
      return SandboxToolResult.failure('not_found', 'Not found: $path');
    } on LinuxSandboxPathException catch (e) {
      return SandboxToolResult.failure(e.code, e.message);
    } catch (e) {
      return SandboxToolResult.failure('io_error', e.toString());
    }
  }

  Future<SandboxToolResult> write(String path, String content) async {
    try {
      await ensureRoot();
      final hostPath = await resolve(path);
      final file = File(hostPath);
      final parent = file.parent;
      if (!LinuxSandboxPath.isUnderRoot(jailRoot.path, parent.path)) {
        return SandboxToolResult.failure(
          'path_escape',
          'Parent path escapes jail: $path',
        );
      }
      await parent.create(recursive: true);
      await file.writeAsString(content, flush: true);
      return SandboxToolResult.success(
        'Wrote ${content.length} characters to $path',
      );
    } on LinuxSandboxPathException catch (e) {
      return SandboxToolResult.failure(e.code, e.message);
    } catch (e) {
      return SandboxToolResult.failure('io_error', e.toString());
    }
  }

  Future<SandboxToolResult> edit(
    String path,
    String oldString,
    String newString,
  ) async {
    if (oldString.isEmpty) {
      return SandboxToolResult.failure(
        'invalid_old_string',
        'old_string must not be empty',
      );
    }
    try {
      await ensureRoot();
      final hostPath = await resolve(path);
      final file = File(hostPath);
      if (!await file.exists()) {
        return SandboxToolResult.failure('not_found', 'Not found: $path');
      }
      final text = await file.readAsString();
      final index = text.indexOf(oldString);
      if (index < 0) {
        return SandboxToolResult.failure(
          'old_string_not_found',
          'old_string not found in $path',
        );
      }
      final updated = text.replaceFirst(oldString, newString);
      await file.writeAsString(updated, flush: true);
      return SandboxToolResult.success('Edited $path');
    } on LinuxSandboxPathException catch (e) {
      return SandboxToolResult.failure(e.code, e.message);
    } catch (e) {
      return SandboxToolResult.failure('io_error', e.toString());
    }
  }

  Future<List<SandboxFsEntry>> listDir([String path = '']) async {
    await ensureRoot();
    final hostPath = await resolve(path);
    final dir = Directory(hostPath);
    if (!await dir.exists()) return const <SandboxFsEntry>[];
    final entries = <SandboxFsEntry>[];
    await for (final entity in dir.list(followLinks: false)) {
      final stat = await entity.stat();
      final isDir = entity is Directory;
      entries.add(
        SandboxFsEntry(
          name: p.basename(entity.path),
          isDirectory: isDir,
          size: isDir ? null : stat.size,
          modifiedAt: stat.modified,
        ),
      );
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  static bool _looksBinary(List<int> bytes) {
    final n = bytes.length < 8192 ? bytes.length : 8192;
    for (var i = 0; i < n; i++) {
      if (bytes[i] == 0) return true;
    }
    return false;
  }
}
