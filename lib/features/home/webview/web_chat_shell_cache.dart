import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'web_chat_protocol.dart';

/// Windows WebView2 virtual host that maps the packaged web chat shell. The
/// access kind is `deny`, so the browser can never read back into the host
/// filesystem — the shell must never load from a `file://` origin
/// (ADR-0042 / CONTEXT.md "Web Chat Secure Origin").
const String webChatWindowsVirtualHost = 'cuplivo-web-chat.invalid';

const List<String> webChatWindowsAssets = <String>[
  'index.html',
  'styles.css',
  'app.mjs',
  'protocol.mjs',
  'vendor/marked.min.js',
  'vendor/purify.min.js',
  'vendor/highlight.min.js',
  'vendor/github.min.css',
  'vendor/katex.min.js',
  'vendor/katex.min.css',
  'vendor/auto-render.min.js',
];

/// Extracts the packaged web chat shell into a versioned temp cache and
/// returns the cached `index.html`. Shared by the interactive viewport and
/// the PDF printer so both reuse one canonical cache + virtual host.
///
/// Concurrent callers (viewport + printer) share a single in-flight
/// preparation so the delete/recreate + marker protocol cannot race.
Future<File> prepareWindowsWebChatShell() =>
    _windowsShellInFlight ??= _prepareWindowsWebChatShell().whenComplete(() {
      _windowsShellInFlight = null;
    });

Future<File>? _windowsShellInFlight;

Future<File> _prepareWindowsWebChatShell() async {
  final temp = await getTemporaryDirectory();
  final directory = Directory(
    '${temp.path}${Platform.pathSeparator}cuplivo_web_chat_$webChatAssetVersion',
  );
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final relativeAssets = <String>{
    ...webChatWindowsAssets,
    for (final asset in manifest.listAssets())
      if (asset.startsWith('assets/web_chat/vendor/fonts/'))
        asset.substring('assets/web_chat/'.length),
  };
  final index = File('${directory.path}${Platform.pathSeparator}index.html');
  if (await _windowsCacheIsComplete(directory, relativeAssets)) {
    await _cleanupOldWindowsCaches(directory);
    return index;
  }
  if (await directory.exists()) {
    await directory.delete(recursive: true);
  }
  await directory.create(recursive: true);
  for (final relative in relativeAssets) {
    final data = await rootBundle.load('assets/web_chat/$relative');
    final output = File(
      '${directory.path}${Platform.pathSeparator}'
      '${relative.replaceAll('/', Platform.pathSeparator)}',
    );
    await output.parent.create(recursive: true);
    await output.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }
  final mermaid = await rootBundle.load('assets/mermaid.min.js');
  await File(
    '${directory.path}${Platform.pathSeparator}mermaid.min.js',
  ).writeAsBytes(
    mermaid.buffer.asUint8List(mermaid.offsetInBytes, mermaid.lengthInBytes),
  );
  final marker = File('${directory.path}${Platform.pathSeparator}.complete');
  final temporaryMarker = File(
    '${directory.path}${Platform.pathSeparator}.complete.tmp',
  );
  await temporaryMarker.writeAsString(webChatAssetVersion, flush: true);
  await temporaryMarker.rename(marker.path);
  await _cleanupOldWindowsCaches(directory);
  return index;
}

Future<bool> _windowsCacheIsComplete(
  Directory directory,
  Set<String> relativeAssets,
) async {
  if (!await directory.exists()) return false;
  final marker = File('${directory.path}${Platform.pathSeparator}.complete');
  try {
    if (!await marker.exists() ||
        await marker.readAsString() != webChatAssetVersion) {
      return false;
    }
    for (final relative in <String>{...relativeAssets, 'mermaid.min.js'}) {
      final file = File(
        '${directory.path}${Platform.pathSeparator}'
        '${relative.replaceAll('/', Platform.pathSeparator)}',
      );
      if (!await file.exists() || await file.length() == 0) return false;
    }
    return true;
  } catch (error) {
    debugPrint(
      'WebChatShellCache: Windows cache validation failed '
      '(${error.runtimeType})',
    );
    return false;
  }
}

Future<void> _cleanupOldWindowsCaches(Directory activeDirectory) async {
  final parent = activeDirectory.parent;
  try {
    await for (final entity in parent.list(followLinks: false)) {
      if (entity is! Directory || entity.path == activeDirectory.path) {
        continue;
      }
      final name = entity.path.split(Platform.pathSeparator).last;
      if (!name.startsWith('cuplivo_web_chat_')) continue;
      try {
        await entity.delete(recursive: true);
      } catch (error) {
        debugPrint(
          'WebChatShellCache: old Windows cache cleanup failed '
          '(${error.runtimeType})',
        );
      }
    }
  } catch (error) {
    debugPrint(
      'WebChatShellCache: Windows cache scan failed (${error.runtimeType})',
    );
  }
}
