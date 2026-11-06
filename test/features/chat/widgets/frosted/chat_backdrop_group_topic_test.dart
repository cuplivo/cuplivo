import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/chat/widgets/chat_assistant_background.dart';
import 'package:Cuplivo/features/chat/widgets/chat_gradient_background.dart';
import 'package:Cuplivo/features/chat/widgets/frosted/chat_frosted_backdrop.dart';

import '../../../../support/business_test_harness.dart';

/// A [ChatService] that only answers "which conversation is open, and whose
/// group does it belong to": the backdrop resolves the owner, nothing else.
class _OpenConversationChat extends ChatService {
  _OpenConversationChat(this.openGroupChatId);

  final String? openGroupChatId;

  @override
  String? get currentConversationId => 'open';

  @override
  Conversation? getConversation(String id) {
    if (id != 'open') return null;
    return Conversation(
      id: 'open',
      title: 'Open',
      messageIds: const <String>[],
      extras: {
        if (openGroupChatId case final groupId?)
          Conversation.groupChatIdKey: groupId,
      },
    );
  }
}

class _Harness {
  _Harness({
    required this.assistants,
    required this.settings,
    required this.chat,
    required this.groups,
  });

  final AssistantProvider assistants;
  final SettingsProvider settings;
  final ChatService chat;
  final GroupChatProvider groups;
}

Future<GroupChatProvider> _groups() async {
  final groups = GroupChatProvider(
    store: ExtensionEntityStore(
      createBusinessTestPreferencesWithDatabase().database,
    ),
  );
  await groups.loaded;
  return groups;
}

Future<AssistantProvider> _gradientAssistant() async {
  final assistants = AssistantProvider(
    preferences: createBusinessTestPreferences(),
  );
  await assistants.loaded;
  final id = await assistants.addAssistant(name: 'Gradient');
  await assistants.setCurrentAssistant(id);
  await assistants.updateAssistant(
    assistants.currentAssistant!.copyWith(useGradientBackground: true),
  );
  return assistants;
}

Widget _app(_Harness harness, Widget child) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AssistantProvider>.value(
        value: harness.assistants,
      ),
      ChangeNotifierProvider<SettingsProvider>.value(value: harness.settings),
      ChangeNotifierProvider<ChatService>.value(value: harness.chat),
      ChangeNotifierProvider<GroupChatProvider>.value(value: harness.groups),
    ],
    child: MaterialApp(home: child),
  );
}

/// Resolves the backdrop spec the way every chat surface does, and hands the
/// last result back so a test can read it after a pump.
Future<ChatBackdropSpec Function()> _pumpSpec(
  WidgetTester tester,
  _Harness harness,
) async {
  late ChatBackdropSpec spec;
  await tester.pumpWidget(
    _app(
      harness,
      Builder(
        builder: (context) {
          spec = ChatBackdropSpec.resolve(context);
          return const SizedBox.expand();
        },
      ),
    ),
  );
  return () => spec;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a group topic drops the selected assistant\'s gradient', (
    tester,
  ) async {
    final groups = await _groups();
    final group = await groups.create(name: 'Reading', memberIds: const ['a']);
    final assistants = await _gradientAssistant();
    final settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
    addTearDown(assistants.dispose);
    addTearDown(settings.dispose);
    final harness = _Harness(
      assistants: assistants,
      settings: settings,
      chat: _OpenConversationChat(group.id),
      groups: groups,
    );

    final spec = await _pumpSpec(tester, harness);

    // A group topic owns no assistant, so the assistant selected *globally*
    // must not lend it a wallpaper or the flowing gradient.
    expect(spec().useGradientBackground, isFalse);
    expect(spec().active, isFalse);
    expect(spec().backgroundRaw, isEmpty);
    expect(spec().surface, isNot(Colors.transparent));
  });

  testWidgets('a 1:1 chat keeps the selected assistant\'s gradient', (
    tester,
  ) async {
    final assistants = await _gradientAssistant();
    final settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
    addTearDown(assistants.dispose);
    addTearDown(settings.dispose);
    final harness = _Harness(
      assistants: assistants,
      settings: settings,
      // Still opens a conversation — just not a topic of any group.
      chat: _OpenConversationChat(null),
      groups: await _groups(),
    );

    final spec = await _pumpSpec(tester, harness);

    expect(spec().useGradientBackground, isTrue);
    expect(spec().active, isTrue);
    expect(spec().surface, Colors.transparent);
  });

  testWidgets('a topic whose group is gone keeps the assistant backdrop', (
    tester,
  ) async {
    // The control for the guard: the group here is *not* in the list, so the
    // topic is an ordinary conversation (the design's "orphan topic degrades to
    // a 1:1") and the assistant backdrop has to stay — otherwise the check
    // would be reading "has a groupChatId" instead of "belongs to a live group".
    final assistants = await _gradientAssistant();
    final settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
    addTearDown(assistants.dispose);
    addTearDown(settings.dispose);
    final harness = _Harness(
      assistants: assistants,
      settings: settings,
      chat: _OpenConversationChat('deleted-group'),
      groups: await _groups(),
    );

    final spec = await _pumpSpec(tester, harness);

    expect(spec().useGradientBackground, isTrue);
    expect(spec().active, isTrue);
  });

  testWidgets('the backdrop widget paints no gradient over a group topic', (
    tester,
  ) async {
    final groups = await _groups();
    final group = await groups.create(name: 'Reading', memberIds: const ['a']);
    final assistants = await _gradientAssistant();
    final settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
    addTearDown(assistants.dispose);
    addTearDown(settings.dispose);
    final harness = _Harness(
      assistants: assistants,
      settings: settings,
      chat: _OpenConversationChat(group.id),
      groups: groups,
    );

    await tester.pumpWidget(
      _app(
        harness,
        ChatFrostedBackdrop(
          backdrop: const ChatAssistantBackground(),
          child: const SizedBox.expand(),
        ),
      ),
    );

    // The widget used to decide this on its own from the assistant model: the
    // gradient host is disabled for a group topic, so a second copy here read a
    // missing artwork and threw.
    expect(tester.takeException(), isNull);
    expect(find.byType(ChatGradientBackground), findsNothing);
  });

  testWidgets('the backdrop widget paints the gradient in a 1:1 chat', (
    tester,
  ) async {
    final assistants = await _gradientAssistant();
    final settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
    addTearDown(assistants.dispose);
    addTearDown(settings.dispose);
    final harness = _Harness(
      assistants: assistants,
      settings: settings,
      chat: _OpenConversationChat(null),
      groups: await _groups(),
    );

    await tester.pumpWidget(
      _app(
        harness,
        ChatFrostedBackdrop(
          backdrop: const ChatAssistantBackground(),
          child: const SizedBox.expand(),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(ChatGradientBackground), findsOneWidget);
  });
}
