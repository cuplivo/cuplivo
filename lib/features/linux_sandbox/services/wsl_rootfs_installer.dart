import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../../core/services/network/dio_http_client.dart';
import 'android_rootfs_urls.dart';

/// Downloads Ubuntu base amd64 and gunzips to a plain `.tar` for `wsl --import`.
class WslRootfsInstaller {
  WslRootfsInstaller({DioHttpClient? httpClient, http.Client? rawClient})
    : _ownsClient = httpClient == null && rawClient == null,
      _client = rawClient ?? httpClient ?? DioHttpClient();

  final http.Client _client;
  final bool _ownsClient;

  static const int _progressStepBytes = 512 * 1024;

  /// Official amd64 Ubuntu base used for the shared WSL distro.
  static String get amd64RootfsUrl => AndroidRootfsUrls.amd64;

  /// Download [url] (default amd64 Ubuntu base) into [tmpDir] and gunzip to
  /// a `.tar` path suitable for `wsl --import`.
  ///
  /// Returns the path to the decompressed `.tar`. Caller owns cleanup.
  Future<String> downloadAndGunzipTar({
    required String tmpDir,
    String? url,
    void Function(double? progress, String stage)? onProgress,
  }) async {
    final dir = Directory(tmpDir);
    await dir.create(recursive: true);
    final archiveGz = File(p.join(dir.path, 'rootfs.tar.gz'));
    final archiveTar = File(p.join(dir.path, 'rootfs.tar'));
    final downloadUrl = url ?? amd64RootfsUrl;

    try {
      onProgress?.call(0.02, 'download');
      await _download(
        url: downloadUrl,
        target: archiveGz,
        onProgress: (fraction) {
          final overall = 0.02 + (fraction.clamp(0.0, 1.0) * 0.70);
          onProgress?.call(overall, 'download');
        },
      );

      onProgress?.call(0.75, 'gunzip');
      await gunzipFileToTar(
        gzipFile: archiveGz,
        tarFile: archiveTar,
        onProgress: (fraction) {
          final overall = 0.75 + (fraction.clamp(0.0, 1.0) * 0.20);
          onProgress?.call(overall, 'gunzip');
        },
      );

      if (!await archiveTar.exists() || await archiveTar.length() == 0) {
        throw StateError('Gunzip produced empty tar');
      }

      try {
        if (await archiveGz.exists()) await archiveGz.delete();
      } catch (e, st) {
        debugPrint('WslRootfsInstaller: cleanup gz failed: $e\n$st');
      }

      onProgress?.call(0.98, 'download_done');
      return archiveTar.path;
    } catch (e) {
      try {
        if (await archiveGz.exists()) await archiveGz.delete();
      } catch (cleanupError, st) {
        debugPrint(
          'WslRootfsInstaller: cleanup gz after failure: $cleanupError\n$st',
        );
      }
      try {
        if (await archiveTar.exists()) await archiveTar.delete();
      } catch (cleanupError, st) {
        debugPrint(
          'WslRootfsInstaller: cleanup tar after failure: $cleanupError\n$st',
        );
      }
      rethrow;
    }
  }

  /// Gunzip [gzipFile] into [tarFile] using the archive package.
  @visibleForTesting
  static Future<void> gunzipFileToTar({
    required File gzipFile,
    required File tarFile,
    void Function(double fraction)? onProgress,
  }) async {
    if (!await gzipFile.exists()) {
      throw StateError('Gzip file missing: ${gzipFile.path}');
    }
    await tarFile.parent.create(recursive: true);
    if (await tarFile.exists()) {
      await tarFile.delete();
    }

    final input = InputFileStream(gzipFile.path);
    try {
      final output = OutputFileStream(tarFile.path);
      try {
        GZipDecoder().decodeStream(input, output);
        onProgress?.call(1.0);
      } finally {
        await output.close();
      }
    } finally {
      await input.close();
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
      } catch (cleanupError, st) {
        debugPrint(
          'WslRootfsInstaller: delete partial download failed: '
          '$cleanupError\n$st',
        );
      }
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

  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }
}
