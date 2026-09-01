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
    expect(css, contains('-webkit-print-color-adjust: exact'));
    expect(css, contains('print-color-adjust: exact'));
  });

  test('Android print adapter keeps the fixed PDF defaults and lifecycle', () {
    final kotlin = File(
      'android/app/src/main/kotlin/com/cup11/cuplivo/'
      'AndroidWebChatPdfHandler.kt',
    ).readAsStringSync();
    expect(kotlin, contains('MediaSize.ISO_A4.asPortrait()'));
    expect(kotlin, contains('PRINT_MARGIN_MILS = 551'));
    expect(kotlin, contains('600, 600'));
    expect(kotlin, contains('PrintAttributes.COLOR_MODE_COLOR'));
    expect(kotlin, contains('delegate.onFinish()'));
    expect(kotlin, contains('disposeCurrentTask(cancelPrint = false)'));
  });

  test('Android PDF failures are localized before reaching the SnackBar', () {
    final source = File(
      'lib/features/chat/widgets/message_export_sheet.dart',
    ).readAsStringSync();
    final pdfExport = RegExp(
      r'Future<void> exportChatMessagesPdf\([\s\S]*?\n}\n\nFuture<void> exportChatMessagesImage',
    ).firstMatch(source)?.group(0);

    expect(pdfExport, isNotNull);
    expect(
      pdfExport,
      contains('message: _pdfExportFailureMessage(l10n, error)'),
    );
    expect(pdfExport, isNot(contains("messageExportSheetExportFailed('\$e')")));
    expect(
      pdfExport,
      contains("'busy' => l10n.messageExportSheetPdfExportInProgress"),
    );
    expect(
      pdfExport,
      contains('messageExportSheetPdfAndroidWebViewUnsupported'),
    );
    expect(pdfExport, contains('messageExportSheetPdfAndroidFailed'));
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
