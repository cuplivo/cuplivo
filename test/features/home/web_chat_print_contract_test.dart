import 'dart:io';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/features/chat/models/tool_ui_part.dart';
import 'package:Cuplivo/features/home/webview/web_chat_protocol.dart';
import 'package:Cuplivo/features/home/webview/web_chat_snapshot.dart';
import 'package:Cuplivo/features/home/webview/web_conversation_pdf_printer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('web chat asset version stays in sync between Dart and JS shell', () {
    final mjs = File('assets/web_chat/protocol.mjs').readAsStringSync();
    final match = RegExp("ASSET_VERSION = '([^']+)'").firstMatch(mjs);
    expect(match, isNotNull, reason: 'ASSET_VERSION export missing in shell');
    expect(match!.group(1), webChatAssetVersion);
  });

  test(
    'web chat font role families stay in sync between Dart and JS shell',
    () {
      final app = File('assets/web_chat/app.mjs').readAsStringSync();
      expect(app, contains(WebChatFontFace.appFaceFamily));
      expect(app, contains(WebChatFontFace.codeFaceFamily));
    },
  );

  test('web chat shell wires the print mode contract', () {
    final app = File('assets/web_chat/app.mjs').readAsStringSync();
    expect(app, contains("searchParams.get('mode') === 'print'"));
    expect(app, contains("type: 'printRenderComplete'"));
    final css = File('assets/web_chat/styles.css').readAsStringSync();
    expect(css, contains('body.print-mode'));
    expect(css, contains('var(--cuplivo-surface)'));
  });

  test('print media bundle answers remote images inside tool results', () {
    const url = 'http://tools.example.test/result.webp';
    final message = ChatMessage(
      id: 'tool-message',
      role: 'assistant',
      content: 'Result',
      conversationId: 'c1',
    );

    final bundle = buildPdfMediaBundle(
      messages: <ChatMessage>[message],
      toolParts: const <String, List<ToolUIPart>>{
        'tool-message': <ToolUIPart>[
          ToolUIPart(
            id: 'tool',
            toolName: 'search_web',
            arguments: <String, dynamic>{},
            content: '![result](http://tools.example.test/result.webp)',
          ),
        ],
      },
    );

    expect(
      bundle.registry[webChatRemoteMediaHandle(url)]?.kind,
      WebChatMediaSourceKind.remoteImage,
    );
    expect(
      bundle.registry[webChatRemoteMediaHandle(url)]?.messageIds,
      contains(message.id),
    );
    expect(bundle.remoteMediaHandles[url], webChatRemoteMediaHandle(url));
  });
}
