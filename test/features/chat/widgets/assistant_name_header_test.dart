import '../../../support/business_test_harness.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tts_provider.dart';
import 'package:Cuplivo/features/chat/widgets/chat_message_widget.dart';
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

/// "Use assistant name" is a per-assistant opt-in and must not depend on the
/// global "show model name" switch (#1007): the reporter had the model-name
/// line off, so the assistant name vanished with it.
Future<SettingsProvider> _settings({required bool showModelName}) async {
  final harness = await createBusinessTestHarness(
    initial: {'display_show_model_name_v1': showModelName},
  );
  final settings = SettingsProvider(harness.preferences);
  await settings.loaded;
  return settings;
}

Widget _buildHarness({
  required SettingsProvider settings,
  required Widget child,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider(
        create: (_) =>
            TtsProvider(preferences: createBusinessTestPreferences()),
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

ChatMessageWidget _assistantMessage({required bool useAssistantName}) {
  return ChatMessageWidget(
    message: ChatMessage(
      role: 'assistant',
      content: 'A letter from the assistant.',
      conversationId: 'conversation-assistant-name',
      modelId: 'glm-5.3-flash',
    ),
    showModelIcon: false,
    useAssistantName: useAssistantName,
    assistantName: useAssistantName ? 'Aria' : null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('assistant message header name', () {
    testWidgets('assistant name shows while the model name line is off', (
      tester,
    ) async {
      final settings = await _settings(showModelName: false);
      await tester.pumpWidget(
        _buildHarness(
          settings: settings,
          child: _assistantMessage(useAssistantName: true),
        ),
      );
      await tester.pump();

      expect(find.text('Aria'), findsOneWidget);
      expect(find.text('glm-5.3-flash'), findsNothing);
    });

    testWidgets('no header name when both switches are off', (tester) async {
      final settings = await _settings(showModelName: false);
      await tester.pumpWidget(
        _buildHarness(
          settings: settings,
          child: _assistantMessage(useAssistantName: false),
        ),
      );
      await tester.pump();

      expect(find.text('Aria'), findsNothing);
      expect(find.text('glm-5.3-flash'), findsNothing);
    });

    testWidgets('model name still shows when the model name line is on', (
      tester,
    ) async {
      final settings = await _settings(showModelName: true);
      await tester.pumpWidget(
        _buildHarness(
          settings: settings,
          child: _assistantMessage(useAssistantName: false),
        ),
      );
      await tester.pump();

      expect(find.text('glm-5.3-flash'), findsOneWidget);
      expect(find.text('Aria'), findsNothing);
    });
  });
}
