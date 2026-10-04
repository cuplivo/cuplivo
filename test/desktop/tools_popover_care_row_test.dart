import 'dart:convert';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/mcp_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/desktop/tools_popover.dart';
import 'package:Cuplivo/features/home/widgets/conversation_proactive_care_sheet.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/business_test_harness.dart';

const String _assistantId = 'assistant-desktop-care';

const Key _careRowKey = ValueKey<String>('desktop-tools-proactive-care');

/// ChatService stub: the popover only needs the conversation lookup, and the
/// shared care opener writes through [updateConversationExtras].
class _FakeChatService extends ChatService {
  _FakeChatService(this.conversation);

  final Conversation? conversation;

  @override
  Conversation? getConversation(String id) =>
      conversation?.id == id ? conversation : null;

  @override
  List<Conversation> getAllConversations() =>
      conversation == null ? const [] : [conversation!];

  @override
  Future<void> updateConversationExtras(
    String conversationId,
    Map<String, dynamic> Function(Map<String, dynamic> current) update,
  ) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AssistantProvider assistants;
  late McpProvider mcp;

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
    mcp = McpProvider(preferences: createBusinessTestPreferences());
  });

  Future<void> pumpPopoverHost(
    WidgetTester tester, {
    Conversation? conversation,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final anchorKey = GlobalKey();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
          ChangeNotifierProvider<McpProvider>.value(value: mcp),
          ChangeNotifierProvider<ChatService>.value(
            value: _FakeChatService(conversation),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => Stack(
                children: [
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: TextButton(
                      onPressed: () => showDesktopToolsPopover(
                        context,
                        anchorKey: anchorKey,
                        assistantId: _assistantId,
                        conversation: conversation,
                      ),
                      child: const Text('open'),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: SizedBox(key: anchorKey, height: 24),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('care row opens the desktop care dialog for a conversation', (
    tester,
  ) async {
    final conversation = Conversation(
      id: 'c1',
      title: 'Chat',
      assistantId: _assistantId,
    );
    await pumpPopoverHost(tester, conversation: conversation);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(_careRowKey), findsOneWidget);

    await tester.tap(find.byKey(_careRowKey));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(ConversationProactiveCareSheet), findsOneWidget);
  });

  testWidgets('care row stays hidden without a conversation', (tester) async {
    await pumpPopoverHost(tester);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(_careRowKey), findsNothing);
    expect(find.byType(ConversationProactiveCareSheet), findsNothing);
  });
}
