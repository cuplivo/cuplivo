import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/subagent/services/subagent_rules.dart';
import 'package:Cuplivo/features/subagent/widgets/subagent_panel.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

/// The one conversation this panel is opened for, and everything behind it.
///
/// A real [ChangeNotifier] underneath: the panel is reachable from a provider
/// tree that listens to the chat service, so a bare `Fake` would die on
/// `addListener`.
class _FakeChat extends ChangeNotifier implements ChatService {
  _FakeChat({required this.parentId, this.conversations = const []});

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fixture',
  );

  final String parentId;
  final List<Conversation> conversations;
  final List<ChatMessage> messages = <ChatMessage>[];

  @override
  List<ChatMessage> getMessages(String conversationId) =>
      conversationId == parentId ? messages : const <ChatMessage>[];

  @override
  List<Conversation> getAllConversations() => conversations;
}

ChatMessage _notice(String childId, {String label = 'auth'}) => ChatMessage(
  id: SubagentResultPart.messageIdFor(childId),
  conversationId: 'parent',
  role: 'user',
  content: 'Subagent finished: $label',
  timestamp: DateTime(2026, 11, 25, 12),
  parts: <MessagePart>[
    SubagentResultPart(
      childConversationId: childId,
      label: label,
      outcome: 'completed',
      elapsedMs: 4200,
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> openPanel(WidgetTester tester, _FakeChat chat) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider<ChatService>.value(value: chat)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      showSubagentPanel(context, conversationId: chat.parentId),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a row that started its own subagents says how many', (
    tester,
  ) async {
    final chat = _FakeChat(
      parentId: 'parent',
      conversations: [
        // The grandchild: one of the two conversations `child-1` started.
        Conversation(
          id: 'grandchild-1',
          title: 'nested',
          extras: const <String, dynamic>{SubagentExtrasKeys.parent: 'child-1'},
        ),
        Conversation(
          id: 'grandchild-2',
          title: 'nested again',
          extras: const <String, dynamic>{SubagentExtrasKeys.parent: 'child-1'},
        ),
        // Started by somebody else: it must not be counted on this row.
        Conversation(
          id: 'other',
          title: 'elsewhere',
          extras: const <String, dynamic>{SubagentExtrasKeys.parent: 'child-9'},
        ),
      ],
    )..messages.add(_notice('child-1'));

    await openPanel(tester, chat);

    // 直系 only: the grandchild is not a row of its own here, but the row that
    // started them says so, or the list would read as the whole chain.
    expect(find.text('auth'), findsOneWidget);
    expect(find.textContaining('+2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a leaf row carries no count at all', (tester) async {
    final chat = _FakeChat(
      parentId: 'parent',
      conversations: const <Conversation>[],
    )..messages.add(_notice('child-1'));

    await openPanel(tester, chat);

    expect(find.text('auth'), findsOneWidget);
    expect(find.textContaining('+'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
