import 'dart:io';

import 'package:Cuplivo/features/home/webview/web_chat_protocol.dart';
import 'package:Cuplivo/features/home/webview/web_chat_shell_cache.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.temporaryPath);

  final String temporaryPath;

  @override
  Future<String?> getTemporaryPath() async => temporaryPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late PathProviderPlatform realPathProvider;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('cuplivo_web_chat_test_');
    realPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(tempRoot.path);
  });

  tearDown(() {
    PathProviderPlatform.instance = realPathProvider;
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  File fileIn(Directory dir, String relative) => File(
    '${dir.path}${Platform.pathSeparator}'
    '${relative.replaceAll('/', Platform.pathSeparator)}',
  );

  Directory cacheDir(String version) => Directory(
    '${tempRoot.path}${Platform.pathSeparator}cuplivo_web_chat_$version',
  );

  File marker(Directory dir) =>
      File('${dir.path}${Platform.pathSeparator}.complete');

  Future<Set<String>> relativeAssets() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    return <String>{
      ...webChatWindowsAssets,
      for (final asset in manifest.listAssets())
        if (asset.startsWith('assets/web_chat/vendor/fonts/'))
          asset.substring('assets/web_chat/'.length),
    };
  }

  Future<void> writeCompleteCache(Directory dir, String version) async {
    for (final relative in <String>{
      ...await relativeAssets(),
      'mermaid.min.js',
    }) {
      final file = fileIn(dir, relative);
      file.createSync(recursive: true);
      file.writeAsStringSync('cached:$relative');
    }
    marker(dir).writeAsStringSync(version);
  }

  test(
    'a complete old cache does not satisfy the current asset version',
    () async {
      // A machine that last ran master (web-chat-v18) keeps a complete
      // versioned cache. The same directory name matches nothing after the
      // asset version was raised, so preparation must extract into a new
      // versioned directory and drop the old one instead of reusing it.
      const staleVersion = 'web-chat-v18';
      await writeCompleteCache(cacheDir(staleVersion), staleVersion);
      expect(cacheDir(staleVersion).existsSync(), isTrue);

      final index = await prepareWindowsWebChatShell();

      final active = cacheDir(webChatAssetVersion);
      expect(webChatAssetVersion, isNot(staleVersion));
      expect(index.path, startsWith(active.path));
      expect(marker(active).readAsStringSync(), webChatAssetVersion);
      expect(fileIn(active, 'index.html').existsSync(), isTrue);
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

    await prepareWindowsWebChatShell();

    expect(fileIn(active, 'index.html').readAsStringSync(), isNot('stale'));
    expect(marker(active).existsSync(), isTrue);
  });

  test(
    'a complete current-version cache is reused without re-extraction',
    () async {
      final active = cacheDir(webChatAssetVersion);
      await writeCompleteCache(active, webChatAssetVersion);
      fileIn(active, 'index.html').writeAsStringSync('sentinel');

      final index = await prepareWindowsWebChatShell();

      expect(index.path, startsWith(active.path));
      expect(
        fileIn(active, 'index.html').readAsStringSync(),
        'sentinel',
        reason: 'a complete cache must not be re-extracted',
      );
    },
  );
}
