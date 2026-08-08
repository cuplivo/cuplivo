import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../../core/services/network/dio_http_client.dart';

/// Downloads Ubuntu base, extracts into `linux/`, and applies rootfs patches.
///
/// Hybrid path: Dart owns download/extract/patch; native code only runs PRoot.
class AndroidRootfsInstaller {
  AndroidRootfsInstaller({DioHttpClient? httpClient, http.Client? rawClient})
    : _ownsClient = httpClient == null && rawClient == null,
      _client = rawClient ?? httpClient ?? DioHttpClient();

  final http.Client _client;
  final bool _ownsClient;

  static const int _progressStepBytes = 512 * 1024;

  Future<void> install({
    required String sandboxRoot,
    required String url,
    void Function(double? progress, String stage)? onProgress,
  }) async {
    final root = Directory(sandboxRoot);
    final tmpDir = Directory(p.join(root.path, 'tmp'));
    final linuxDir = Directory(p.join(root.path, 'linux'));
    final stagingDir = Directory(p.join(tmpDir.path, 'rootfs-staging'));
    final archiveFile = File(p.join(tmpDir.path, 'rootfs.tar.gz'));

    await tmpDir.create(recursive: true);
    if (await stagingDir.exists()) {
      await stagingDir.delete(recursive: true);
    }
    await stagingDir.create(recursive: true);

    try {
      onProgress?.call(0.02, 'download');
      await _download(
        url: url,
        target: archiveFile,
        onProgress: (fraction) {
          // Download occupies 0.02..0.70 of overall progress.
          final overall = 0.02 + (fraction.clamp(0.0, 1.0) * 0.68);
          onProgress?.call(overall, 'download');
        },
      );

      onProgress?.call(0.72, 'extract');
      await _extractTarGz(
        archiveFile: archiveFile,
        targetDir: stagingDir,
        onProgress: (fraction) {
          final overall = 0.72 + (fraction.clamp(0.0, 1.0) * 0.20);
          onProgress?.call(overall, 'extract');
        },
      );

      onProgress?.call(0.93, 'install');
      if (await linuxDir.exists()) {
        await linuxDir.delete(recursive: true);
      }
      try {
        await stagingDir.rename(linuxDir.path);
      } catch (_) {
        await _copyDirectory(stagingDir, linuxDir);
        await stagingDir.delete(recursive: true);
      }

      onProgress?.call(0.96, 'patch');
      await AndroidRootfsPatcher.patch(linuxDir);

      final sh = File(p.join(linuxDir.path, 'bin', 'sh'));
      if (!await sh.exists()) {
        throw StateError('Rootfs extract incomplete: missing bin/sh');
      }
      onProgress?.call(0.99, 'verify');
    } finally {
      try {
        if (await archiveFile.exists()) await archiveFile.delete();
      } catch (e, st) {
        debugPrint('AndroidRootfsInstaller: cleanup archive failed: $e\n$st');
      }
      try {
        if (await stagingDir.exists()) {
          await stagingDir.delete(recursive: true);
        }
      } catch (e, st) {
        debugPrint('AndroidRootfsInstaller: cleanup staging failed: $e\n$st');
      }
    }
  }

  Future<void> _download({
    required String url,
    required File target,
    required void Function(double fraction) onProgress,
  }) async {
    final uri = Uri.parse(url);
    final request = http.Request('GET', uri);
    request.headers['User-Agent'] = 'Cuplivo';
    final response = await _client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Rootfs download failed: HTTP ${response.statusCode}',
        uri: uri,
      );
    }

    final total = response.contentLength;
    await target.parent.create(recursive: true);
    final sink = target.openWrite();
    var read = 0;
    var lastReport = 0;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        read += chunk.length;
        if (total != null && total > 0) {
          if (read - lastReport >= _progressStepBytes || read >= total) {
            lastReport = read;
            onProgress(read / total);
          }
        } else if (read - lastReport >= _progressStepBytes) {
          lastReport = read;
          onProgress(0.0);
        }
      }
      await sink.flush();
    } catch (e) {
      await sink.close();
      try {
        if (await target.exists()) await target.delete();
      } catch (_) {}
      rethrow;
    }
    await sink.close();
    if (read == 0) {
      throw StateError('Rootfs download produced empty file');
    }
    if (total == null || total <= 0) {
      onProgress(1.0);
    }
  }

  @visibleForTesting
  Future<void> extractTarGzForTest({
    required File archiveFile,
    required Directory targetDir,
    void Function(double fraction)? onProgress,
  }) {
    return _extractTarGz(
      archiveFile: archiveFile,
      targetDir: targetDir,
      onProgress: onProgress ?? (_) {},
    );
  }

  @visibleForTesting
  static String? normalizeTarPathForTest(String raw) => _normalizeTarPath(raw);

  Future<void> _extractTarGz({
    required File archiveFile,
    required Directory targetDir,
    required void Function(double fraction) onProgress,
  }) async {
    final input = InputFileStream(archiveFile.path);
    try {
      final tarBytes = OutputMemoryStream();
      GZipDecoder().decodeStream(input, tarBytes);
      final tarInput = InputMemoryStream(tarBytes.getBytes());
      final archive = TarDecoder().decodeStream(tarInput);
      final total = archive.length;
      var index = 0;
      for (final entry in archive) {
        index++;
        await _extractEntry(entry, targetDir);
        if (total > 0 && (index % 50 == 0 || index == total)) {
          onProgress(index / total);
        }
      }
      onProgress(1.0);
    } finally {
      await input.close();
    }
  }

  Future<void> _extractEntry(ArchiveFile entry, Directory targetDir) async {
    final relative = _normalizeTarPath(entry.name);
    if (relative == null) return;

    final destPath = p.join(targetDir.path, relative);
    if (!_isUnderRoot(targetDir.path, destPath)) {
      throw StateError('Rootfs entry escapes target directory: ${entry.name}');
    }

    if (entry.isSymbolicLink) {
      final linkTarget = entry.symbolicLink ?? '';
      if (linkTarget.isEmpty) return;
      if (!p.isAbsolute(linkTarget)) {
        final resolved = p.normalize(p.join(p.dirname(destPath), linkTarget));
        if (!_isUnderRoot(targetDir.path, resolved)) {
          debugPrint(
            'AndroidRootfsInstaller: skip escaping symlink ${entry.name} -> $linkTarget',
          );
          return;
        }
      }
      final parent = Directory(p.dirname(destPath));
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      final existing = FileSystemEntity.typeSync(destPath, followLinks: false);
      if (existing != FileSystemEntityType.notFound) {
        await _deleteFsPath(destPath, existing);
      }
      await Link(destPath).create(linkTarget, recursive: false);
      return;
    }

    if (entry.isDirectory || !entry.isFile) {
      await Directory(destPath).create(recursive: true);
      return;
    }

    final parent = Directory(p.dirname(destPath));
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    final output = OutputFileStream(destPath);
    try {
      entry.writeContent(output);
    } finally {
      await output.close();
    }
    final mode = entry.unixPermissions;
    final executable = (mode & 0x49) != 0; // owner/group/other execute
    if (executable) {
      try {
        await Process.run('chmod', ['+x', destPath]);
      } catch (e) {
        debugPrint('AndroidRootfsInstaller: chmod +x failed $destPath: $e');
      }
    }
  }

  /// Returns null for blank / self / skip entries.
  static String? _normalizeTarPath(String raw) {
    var path = raw.replaceAll('\\', '/').trim();
    if (path.isEmpty) return null;
    while (path.startsWith('./')) {
      path = path.substring(2);
    }
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    if (path.isEmpty || path == '.') return null;
    if (path.contains('\u0000')) {
      throw StateError('Rootfs entry path contains NUL');
    }
    final parts = path.split('/');
    if (parts.any((s) => s == '..')) {
      throw StateError('Rootfs entry escapes target directory: $raw');
    }
    return parts.where((s) => s.isNotEmpty && s != '.').join('/');
  }

  static bool _isUnderRoot(String root, String candidate) {
    final rootCanon = p.normalize(root);
    final candCanon = p.normalize(candidate);
    if (candCanon == rootCanon) return true;
    final prefix = rootCanon.endsWith(p.separator)
        ? rootCanon
        : '$rootCanon${p.separator}';
    return candCanon.startsWith(prefix);
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

  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }
}

/// Minimal rootfs patches so DNS/locale/tmp work under PRoot.
class AndroidRootfsPatcher {
  AndroidRootfsPatcher._();

  static const _defaultDns = ['1.1.1.1', '8.8.8.8', '223.5.5.5'];
  static const _localResolvers = {'127.0.0.1', '127.0.0.53', '::1'};

  static Future<void> patch(Directory linuxDir) async {
    final etcDir = Directory(p.join(linuxDir.path, 'etc'));
    if (!await etcDir.exists()) return;

    await _ensureDns(etcDir);
    await _ensureHosts(etcDir);
    await _ensureHostname(etcDir);
    await _ensureLocale(etcDir);
    await _ensureTempDirs(linuxDir);
  }

  static Future<void> _ensureDns(Directory etcDir) async {
    final resolv = File(p.join(etcDir.path, 'resolv.conf'));
    var shouldWrite = true;
    final type = FileSystemEntity.typeSync(resolv.path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      final text = await resolv.readAsString();
      final hasPublic = text.split('\n').any((line) {
        final trimmed = line.trimLeft();
        if (!trimmed.startsWith('nameserver ')) return false;
        final server = trimmed.substring('nameserver '.length).trim();
        return server.isNotEmpty && !_localResolvers.contains(server);
      });
      shouldWrite = !hasPublic;
    }
    if (!shouldWrite) return;

    if (type != FileSystemEntityType.notFound) {
      await _deleteFsPath(resolv.path, type);
    }
    final buf = StringBuffer()
      ..writeln('# Generated by Cuplivo sandbox.')
      ..writeAll(_defaultDns.map((s) => 'nameserver $s\n'))
      ..writeln('options edns0 trust-ad');
    await resolv.writeAsString(buf.toString(), flush: true);
  }

  static Future<void> _ensureHosts(Directory etcDir) async {
    final hosts = File(p.join(etcDir.path, 'hosts'));
    final existing = await hosts.exists() ? await hosts.readAsString() : '';
    final lines = existing.split('\n');
    final hasV4 = lines.any((line) {
      final parts = line.split('#').first.trim().split(RegExp(r'\s+'));
      return parts.isNotEmpty &&
          parts.first == '127.0.0.1' &&
          parts.contains('localhost');
    });
    final hasV6 = lines.any((line) {
      final parts = line.split('#').first.trim().split(RegExp(r'\s+'));
      return parts.isNotEmpty &&
          parts.first == '::1' &&
          parts.contains('localhost');
    });
    if (hasV4 && hasV6) return;

    final buf = StringBuffer(existing);
    if (existing.isNotEmpty && !existing.endsWith('\n')) buf.writeln();
    if (!hasV4) buf.writeln('127.0.0.1 localhost');
    if (!hasV6) buf.writeln('::1 localhost ip6-localhost ip6-loopback');
    await hosts.writeAsString(buf.toString(), flush: true);
  }

  static Future<void> _ensureHostname(Directory etcDir) async {
    final file = File(p.join(etcDir.path, 'hostname'));
    if (await file.exists()) {
      final text = (await file.readAsString()).trim();
      if (text.isNotEmpty) return;
    }
    await file.writeAsString('localhost\n', flush: true);
  }

  static Future<void> _ensureLocale(Directory etcDir) async {
    final defaultDir = Directory(p.join(etcDir.path, 'default'));
    await defaultDir.create(recursive: true);
    final file = File(p.join(defaultDir.path, 'locale'));
    final existing = await file.exists() ? await file.readAsString() : '';
    if (existing.split('\n').any((l) => l.trim().startsWith('LANG='))) {
      return;
    }
    final buf = StringBuffer(existing);
    if (existing.isNotEmpty && !existing.endsWith('\n')) buf.writeln();
    buf.writeln('LANG=C.UTF-8');
    await file.writeAsString(buf.toString(), flush: true);
  }

  static Future<void> _ensureTempDirs(Directory linuxDir) async {
    for (final rel in ['tmp', 'var/tmp', 'root']) {
      final dir = Directory(p.join(linuxDir.path, rel));
      await dir.create(recursive: true);
    }
    for (final rel in ['tmp', 'var/tmp']) {
      final dir = Directory(p.join(linuxDir.path, rel));
      try {
        await Process.run('chmod', ['1777', dir.path]);
      } catch (e) {
        debugPrint('AndroidRootfsPatcher: chmod $rel failed: $e');
      }
    }
  }
}

Future<void> _deleteFsPath(String path, FileSystemEntityType type) async {
  switch (type) {
    case FileSystemEntityType.directory:
      await Directory(path).delete(recursive: true);
    case FileSystemEntityType.link:
      await Link(path).delete();
    case FileSystemEntityType.file:
    case FileSystemEntityType.notFound:
    case FileSystemEntityType.pipe:
    case FileSystemEntityType.unixDomainSock:
      await File(path).delete();
  }
}
