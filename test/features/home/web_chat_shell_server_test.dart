import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/home/webview/local_web_chat_shell_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('path allowlist', () {
    test('maps the shell tree and mermaid markers to asset keys', () {
      expect(
        LocalWebChatShellServer.assetKeyForPath('/assets/web_chat/index.html'),
        'assets/web_chat/index.html',
      );
      expect(
        LocalWebChatShellServer.assetKeyForPath('/assets/web_chat/app.mjs'),
        'assets/web_chat/app.mjs',
      );
      expect(
        LocalWebChatShellServer.assetKeyForPath(
          '/assets/web_chat/vendor/fonts/katex.woff2',
        ),
        'assets/web_chat/vendor/fonts/katex.woff2',
      );
      expect(
        LocalWebChatShellServer.assetKeyForPath('/assets/mermaid.min.js'),
        'assets/mermaid.min.js',
      );
    });

    test('rejects traversal, separators, and out-of-scope paths', () {
      expect(
        LocalWebChatShellServer.assetKeyForPath('/assets/../pubspec.yaml'),
        isNull,
      );
      expect(
        LocalWebChatShellServer.assetKeyForPath(
          '/assets/web_chat/../../pubspec.yaml',
        ),
        isNull,
      );
      expect(
        LocalWebChatShellServer.assetKeyForPath(
          '/assets/web_chat/..\\pubspec.yaml',
        ),
        isNull,
      );
      expect(
        LocalWebChatShellServer.assetKeyForPath(
          '/assets/%2e%2e%2fpubspec.yaml',
        ),
        isNull,
      );
      expect(
        LocalWebChatShellServer.assetKeyForPath(
          '/assets/web_chat/%2e%2e%2f..%2fpubspec.yaml',
        ),
        isNull,
      );
      expect(
        LocalWebChatShellServer.assetKeyForPath(
          '/assets/web_chat/%5c..%5cpubspec.yaml',
        ),
        isNull,
      );
      expect(
        LocalWebChatShellServer.assetKeyForPath('/assets/%zz/pubspec.yaml'),
        isNull,
      );
      expect(
        LocalWebChatShellServer.assetKeyForPath('/assets/web_chat'),
        isNull,
      );
      expect(
        LocalWebChatShellServer.assetKeyForPath('/assets/icons/kelivo.png'),
        isNull,
      );
      expect(
        LocalWebChatShellServer.assetKeyForPath('/workspaces/foo'),
        isNull,
      );
      expect(
        LocalWebChatShellServer.assetKeyForPath('assets/web_chat/index.html'),
        isNull,
      );
    });
  });

  group('content types', () {
    test('module and shell assets resolve to strict browser MIME types', () {
      expect(
        LocalWebChatShellServer.contentTypeForKey('assets/web_chat/app.mjs'),
        'text/javascript; charset=utf-8',
      );
      expect(
        LocalWebChatShellServer.contentTypeForKey('assets/mermaid.min.js'),
        'text/javascript; charset=utf-8',
      );
      expect(
        LocalWebChatShellServer.contentTypeForKey('assets/web_chat/index.html'),
        'text/html; charset=utf-8',
      );
      expect(
        LocalWebChatShellServer.contentTypeForKey('assets/web_chat/styles.css'),
        'text/css; charset=utf-8',
      );
      expect(
        LocalWebChatShellServer.contentTypeForKey(
          'assets/web_chat/vendor/fonts/katex.woff2',
        ),
        'font/woff2',
      );
    });
  });

  group('loopback server', () {
    late LocalWebChatShellServer server;
    late HttpOverrides? originalHttpOverrides;

    setUpAll(() async {
      // TestWidgetsFlutterBinding installs a global Http client mock that
      // answers 400 to everything; the loopback tests need real sockets.
      originalHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      server = await LocalWebChatShellServer.acquire();
    });

    tearDownAll(() {
      HttpOverrides.global = originalHttpOverrides;
    });

    test('acquire is idempotent for the process lifetime', () async {
      expect(
        identical(await LocalWebChatShellServer.acquire(), server),
        isTrue,
      );
    });

    test('serves the shell origin with whitelisted assets', () async {
      final client = HttpClient();
      try {
        final index = await (await client.getUrl(server.shellUri)).close();
        expect(index.statusCode, HttpStatus.ok);
        expect(index.headers.contentType?.mimeType, 'text/html');
        await index.drain<void>();

        final app = await (await client.getUrl(
          server.shellUri.replace(path: '/assets/web_chat/app.mjs'),
        )).close();
        expect(app.statusCode, HttpStatus.ok);
        expect(app.headers.contentType?.mimeType, 'text/javascript');
        await app.drain<void>();

        // The shell resolves mermaid as ../mermaid.min.js from app.mjs.
        final mermaid = await (await client.getUrl(
          server.shellUri.replace(path: '/assets/mermaid.min.js'),
        )).close();
        expect(mermaid.statusCode, HttpStatus.ok);
        await mermaid.drain<void>();

        expect(
          server.isLocalShellUri(
            server.shellUri.replace(path: '/assets/web_chat/app.mjs'),
          ),
          isTrue,
        );
      } finally {
        client.close(force: true);
      }
    });

    test('rejects out-of-scope paths and non-GET methods', () async {
      final client = HttpClient();
      try {
        final outside = await (await client.getUrl(
          server.shellUri.replace(path: '/pubspec.yaml'),
        )).close();
        expect(outside.statusCode, HttpStatus.notFound);
        await outside.drain<void>();

        final request = await client.postUrl(server.shellUri);
        final response = await request.close();
        expect(response.statusCode, HttpStatus.methodNotAllowed);
        await response.drain<void>();

        expect(
          server.isLocalShellUri(
            server.shellUri.replace(port: server.port + 1),
          ),
          isFalse,
        );
        expect(
          server.isLocalShellUri(
            server.shellUri.replace(path: '/assets/icons/kelivo.png'),
          ),
          isFalse,
        );
        expect(
          server.isLocalShellUri(server.shellUri.replace(host: 'localhost')),
          isFalse,
        );
      } finally {
        client.close(force: true);
      }
    });
  });
}
