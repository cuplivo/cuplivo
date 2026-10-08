import 'dart:convert';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/assistant/pages/assistant_settings_edit_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

const String _assistantId = 'assistant-desktop-roleplay';

const Key _decisionHistoryRowKey = ValueKey(
  'assistant-proactive-decision-history-limit',
);
const Key _careTabKey = ValueKey('assistant-roleplay-tab');

class _FakeChatService extends ChatService {
  _FakeChatService(this.conversations);

  final List<Conversation> conversations;

  @override
  List<Conversation> getAllConversations() =>
      List<Conversation>.of(conversations);

  @override
  Conversation? getConversation(String id) =>
      conversations.where((c) => c.id == id).firstOrNull;

  @override
  Future<void> updateConversationExtras(
    String conversationId,
    Map<String, dynamic> Function(Map<String, dynamic> current) update,
  ) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AssistantProvider assistants;
  late SettingsProvider settings;

  setUp(() async {
    final assistantPreferences = createBusinessTestPreferences();
    await assistantPreferences.load();
    await assistantPreferences.setString(
      'assistants_v1',
      jsonEncode([
        Assistant(
          id: _assistantId,
          name: 'Tester',
          enableProactiveCare: true,
        ).toJson(),
      ]),
    );
    await assistantPreferences.setString(
      'current_assistant_id_v1',
      _assistantId,
    );
    assistants = AssistantProvider(preferences: assistantPreferences);
    await assistants.loaded;
    settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
  });

  Future<(AppLocalizations, ChatService)> pumpDialogHost(
    WidgetTester tester, {
    required Size viewSize,
  }) async {
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final chat = _FakeChatService([
      Conversation(id: 'c1', title: 'Chat', assistantId: _assistantId),
    ]);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<ChatService>.value(value: chat),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAssistantDesktopDialog(
                  context,
                  assistantId: _assistantId,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return (AppLocalizations.of(tester.element(find.byType(Scaffold)))!, chat);
  }

  Future<void> openRoleplayPane(
    WidgetTester tester,
    AppLocalizations l10n,
  ) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      find.text(l10n.assistantEditPageRoleplayTab),
      findsOneWidget,
      reason: 'the desktop assistant dialog must offer the roleplay tab',
    );

    await tester.tap(find.text(l10n.assistantEditPageRoleplayTab));
    await tester.pumpAndSettle();
  }

  testWidgets('desktop assistant dialog hosts the roleplay care pane', (
    tester,
  ) async {
    final (l10n, _) = await pumpDialogHost(
      tester,
      viewSize: const Size(1400, 900),
    );
    await openRoleplayPane(tester, l10n);

    expect(find.byKey(_careTabKey), findsOneWidget);
    expect(
      find.text(l10n.assistantEditProactiveCareFeatureTitle),
      findsOneWidget,
    );
    expect(
      find.byKey(AssistantSettingsEditRoleplayTab.conversationTimesSectionKey),
      findsOneWidget,
    );
    expect(find.byKey(_decisionHistoryRowKey), findsOneWidget);
  });

  testWidgets('decision history picker is a dialog on desktop', (tester) async {
    final (l10n, _) = await pumpDialogHost(
      tester,
      viewSize: const Size(1400, 900),
    );
    await openRoleplayPane(tester, l10n);

    await tester.tap(find.byKey(_decisionHistoryRowKey));
    await tester.pumpAndSettle();

    expect(
      find.byType(BottomSheet),
      findsNothing,
      reason: 'desktop must not use bottom sheets (AGENTS.md)',
    );
    expect(
      find.text(l10n.assistantEditProactiveCareDecisionHistoryLimitTitle),
      findsWidgets,
    );
  });

  testWidgets('decision history picker stays a sheet below the desktop '
      'breakpoint', (tester) async {
    final (l10n, _) = await pumpDialogHost(
      tester,
      viewSize: const Size(900, 900),
    );
    await openRoleplayPane(tester, l10n);

    await tester.tap(find.byKey(_decisionHistoryRowKey));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
  });
}
