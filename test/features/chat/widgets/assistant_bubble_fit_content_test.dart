import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tts_provider.dart';
import 'package:Cuplivo/features/chat/widgets/chat_message_widget.dart';
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

SettingsProvider _createSettings({required bool fitContent}) {
  SharedPreferences.setMockInitialValues({});
  businessPrefs = BusinessPreferences.memoryForTests({
    'display_chat_message_background_style_v1': 'solid',
    if (fitContent) 'display_assistant_bubble_fit_content_v1': true,
  });
  return SettingsProvider(preferences: businessPrefs);
}

Widget _buildHarness({
  required SettingsProvider settings,
  required Widget child,
}) {
  return MultiProvider(
    providers: [
      Provider<BusinessPreferences>.value(value: businessPrefs),
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider(
        create: (_) => TtsProvider(preferences: businessPrefs),
      ),
      ChangeNotifierProvider(create: (_) => ToolApprovalService()),
      ChangeNotifierProvider(create: (_) => AskUserInteractionService()),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
}

Future<double> _bubbleWidth(
  WidgetTester tester, {
  required bool fitContent,
  bool waiting = false,
}) async {
  final settings = _createSettings(fitContent: fitContent);
  final message = ChatMessage(
    role: 'assistant',
    content: waiting ? '' : 'OK',
    conversationId: 'conversation-fit-content',
    isStreaming: waiting,
  );
  await tester.pumpWidget(
    _buildHarness(
      settings: settings,
      child: ChatMessageWidget(message: message, showModelIcon: false),
    ),
  );
  if (waiting) {
    await tester.pump();
    return tester
        .getSize(
          find
              .ancestor(
                of: find.byType(LoadingIndicator),
                matching: find.byType(DecoratedBox),
              )
              .first,
        )
        .width;
  }
  await tester.pumpAndSettle();
  return tester.getSize(find.byKey(ValueKey('assistant_${message.id}'))).width;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('fit-content option shrinks the assistant bubble to its text', (
    tester,
  ) async {
    final spanning = await _bubbleWidth(tester, fitContent: false);
    final hugging = await _bubbleWidth(tester, fitContent: true);
    expect(hugging, lessThan(spanning));
  });

  testWidgets('waiting bubble hugs the indicator too', (tester) async {
    final spanning = await _bubbleWidth(
      tester,
      fitContent: false,
      waiting: true,
    );
    final hugging = await _bubbleWidth(tester, fitContent: true, waiting: true);
    expect(hugging, lessThan(spanning));
  });
}
