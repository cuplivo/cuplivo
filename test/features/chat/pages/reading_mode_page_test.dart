import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/chat/pages/reading_mode_page.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

ChatMessage _message(String content) {
  return ChatMessage(role: 'assistant', content: content, conversationId: 'c1');
}

Widget _harness(
  ChatMessage message, {
  String? assistantName,
  Map<String, Object> prefs = const <String, Object>{},
}) {
  SharedPreferences.setMockInitialValues(prefs);
  return ChangeNotifierProvider(
    create: (_) => SettingsProvider(),
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ReadingModePage(message: message, assistantName: assistantName),
    ),
  );
}

void main() {
  testWidgets('renders think-stripped content, never the <think> body', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(_message('Hello <think>secret</think> visible world')),
    );

    expect(find.textContaining('Hello'), findsWidgets);
    expect(find.textContaining('secret'), findsNothing);
  });

  testWidgets('shows the assistant name in the toolbar', (tester) async {
    await tester.pumpWidget(
      _harness(_message('hello'), assistantName: 'My Assistant'),
    );

    expect(find.text('My Assistant'), findsOneWidget);
  });

  testWidgets('copy-all copies the visual content, not raw content', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      _harness(_message('Hello <think>secret</think> visible world')),
    );
    await tester.tap(find.byIcon(Lucide.Copy));
    await tester.pump();

    final setData = calls
        .where((c) => c.method == 'Clipboard.setData')
        .toList();
    expect(setData, hasLength(1));
    final args = setData.single.arguments as Map;
    expect(args['text'], 'Hello  visible world');

    // Let the snackbar duration elapse so its ticker is disposed cleanly.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('font + and - step by 2 around the persisted value', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(_message('hello')));

    expect(find.text('18'), findsOneWidget);

    await tester.tap(find.byIcon(Lucide.Plus));
    await tester.pumpAndSettle();
    expect(find.text('20'), findsOneWidget);

    await tester.tap(find.byIcon(Lucide.Minus));
    await tester.pumpAndSettle();
    expect(find.text('18'), findsOneWidget);
  });

  testWidgets('honors the persisted reader font size', (tester) async {
    await tester.pumpWidget(
      _harness(_message('hello'), prefs: {'reader_font_size_v1': 22}),
    );
    await tester.pumpAndSettle();

    expect(find.text('22'), findsOneWidget);
  });
}
