import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/chat/widgets/message_more_sheet.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

import 'support/business_test_harness.dart';

ChatMessage _message({String id = 'message-1'}) {
  return ChatMessage(
    id: id,
    role: 'assistant',
    content: 'hello',
    conversationId: 'conversation-1',
  );
}

Future<void> _openMoreSheet(
  WidgetTester tester, {
  required bool canDeleteAllVersions,
  bool canCreateBranch = true,
  String messageId = 'message-1',
}) async {
  await tester.pumpWidget(
    // The sheet's tiles are IosCardPress, which reads the haptics preference.
    ChangeNotifierProvider(
      create: (_) => SettingsProvider(createBusinessTestPreferences()),
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () {
                  showMessageMoreSheet(
                    context,
                    _message(id: messageId),
                    canDeleteAllVersions: canDeleteAllVersions,
                    canCreateBranch: canCreateBranch,
                  );
                },
                child: const Text('open'),
              );
            },
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  final mobilePlatforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.iOS,
  });
  testWidgets('多版本消息菜单显示删除全部版本', (tester) async {
    await _openMoreSheet(tester, canDeleteAllVersions: true);

    expect(find.text('Select Messages'), findsOneWidget);
    expect(find.text('Create Branch'), findsOneWidget);
    expect(find.text('Delete This Version'), findsOneWidget);
    expect(find.text('Delete All Versions'), findsOneWidget);
  });

  testWidgets('单版本消息菜单不显示删除全部版本', (tester) async {
    await _openMoreSheet(tester, canDeleteAllVersions: false);

    expect(find.text('Select Messages'), findsOneWidget);
    expect(find.text('Delete This Version'), findsOneWidget);
    expect(find.text('Delete All Versions'), findsNothing);
  });

  testWidgets('临时会话消息菜单不显示创建分支', (tester) async {
    await _openMoreSheet(
      tester,
      canDeleteAllVersions: false,
      canCreateBranch: false,
    );

    expect(find.text('Create Branch'), findsNothing);
  });

  testWidgets('mobile offers the copy entry for the registered scheme', (
    tester,
  ) async {
    await _openMoreSheet(tester, canDeleteAllVersions: false);

    expect(find.text('Copy Link'), findsOneWidget);
  }, variant: mobilePlatforms);

  testWidgets('mobile copies the link anchored on this message', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? clipboard;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    try {
      await _openMoreSheet(tester, canDeleteAllVersions: false);
      expect(find.text('Copy Link'), findsOneWidget);

      await tester.tap(find.text('Copy Link'));
      await tester.pumpAndSettle();

      expect(
        clipboard,
        'cuplivo://conversation/conversation-1?message=message-1',
      );
      // Let the confirmation toast dismiss before the tree goes away.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    } finally {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    }
  }, variant: mobilePlatforms);

  testWidgets('mobile offers no link for an id the grammar cannot carry', (
    tester,
  ) async {
    await _openMoreSheet(
      tester,
      canDeleteAllVersions: false,
      // Past the cap: the link would be dropped on the way back in.
      messageId: 'x' * 201,
    );

    // The sheet is open (its neighbour is there), so the absence below is the
    // gate and not a sheet that never appeared.
    expect(find.text('Select Messages'), findsOneWidget);
    expect(find.text('Copy Link'), findsNothing);
  }, variant: mobilePlatforms);

  testWidgets('a settled message offers Reply', (tester) async {
    await _openMoreSheet(tester, canDeleteAllVersions: false);

    expect(find.text('Reply'), findsOneWidget);
  });

  testWidgets('a streaming message offers no Reply', (tester) async {
    // The whole-message citation would freeze a reply that is still being
    // written, so the entry is withheld (docs/adr/0012).
    await _openMoreSheet(
      tester,
      canDeleteAllVersions: false,
      isStreaming: true,
    );

    expect(find.text('Select Messages'), findsOneWidget);
    expect(find.text('Reply'), findsNothing);
  });
}
