import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:Cuplivo/features/home/webview/web_chat_protocol.dart';
import 'package:Cuplivo/features/home/webview/web_chat_shell_cache.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('cuplivo_web_chat_test_');
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  ByteData bytes(String path) =>
      ByteData.sublistView(utf8.encode('content of $path'));

  Future<ByteData> loadAsset(String path) async => bytes(path);

  File fileIn(Directory dir, String relative) => File(
    '${dir.path}${Platform.pathSeparator}'
    '${relative.replaceAll('/', Platform.pathSeparator)}',
  );

  void writeCompleteCache(Directory dir) {
    for (final relative in <String>[
      ...webChatWindowsAssets,
      'mermaid.min.js',
    ]) {
      final file = fileIn(dir, relative);
      file.createSync(recursive: true);
      file.writeAsStringSync('cached:$relative');
    }
    File(
      '${dir.path}${Platform.pathSeparator}.complete',
    ).writeAsStringSync(webChatAssetVersion);
  }

  Directory cacheDir(String version) => Directory(
    '${tempRoot.path}${Platform.pathSeparator}cuplivo_web_chat_$version',
  );

  test(
    'a complete old cache does not satisfy the current asset version',
    () async {
      // A machine that last ran master (web-chat-v18) keeps a complete
      // versioned cache. The same directory name matches nothing after
      // `web-chat-v18` was retired, so preparation must extract into a new
      // versioned directory and drop the old one instead of reusing it.
      final staleVersion = 'web-chat-v18';
      writeCompleteCache(cacheDir(staleVersion));
      expect(cacheDir(staleVersion).existsSync(), isTrue);

      final index = await prepareWindowsWebChatShellWith(
        tempRoot: tempRoot,
        manifestAssets: const <String>[],
        loadAsset: loadAsset,
      );

      final active = cacheDir(webChatAssetVersion);
      expect(webChatAssetVersion, isNot(staleVersion));
      expect(index.path, startsWith(active.path));
      expect(
        fileIn(active, 'index.html').readAsStringSync(),
        'content of assets/web_chat/index.html',
      );
      expect(
        File(
          '${active.path}${Platform.pathSeparator}.complete',
        ).readAsStringSync(),
        webChatAssetVersion,
      );
      expect(fileIn(active, 'mermaid.min.js').existsSync(), isTrue);
      expect(
        cacheDir(staleVersion).existsSync(),
        isFalse,
        reason: 'old-version caches must be cleaned up',
      );
    },
  );

  test('an incomplete current-version cache is re-extracted', () async {
    final active = cacheDir(webChatAssetVersion);
    fileIn(active, 'index.html')
      ..createSync(recursive: true)
      ..writeAsStringSync('stale');

    await prepareWindowsWebChatShellWith(
      tempRoot: tempRoot,
      manifestAssets: const <String>[],
      loadAsset: loadAsset,
    );

    expect(
      fileIn(active, 'index.html').readAsStringSync(),
      'content of assets/web_chat/index.html',
    );
    expect(
      File('${active.path}${Platform.pathSeparator}.complete').existsSync(),
      isTrue,
    );
  });

  test(
    'a complete current-version cache is reused without re-extraction',
    () async {
      final active = cacheDir(webChatAssetVersion);
      writeCompleteCache(active);

      final index = await prepareWindowsWebChatShellWith(
        tempRoot: tempRoot,
        manifestAssets: const <String>[],
        loadAsset: loadAsset,
      );

      expect(index.path, startsWith(active.path));
      expect(
        fileIn(active, 'index.html').readAsStringSync(),
        'cached:index.html',
        reason: 'a complete cache must not be re-extracted',
      );
    },
  );
}
