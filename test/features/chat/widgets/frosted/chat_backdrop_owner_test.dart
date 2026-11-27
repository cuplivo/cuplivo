import 'dart:convert';

import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/chat/widgets/frosted/chat_frosted_backdrop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../../support/business_test_harness.dart';

/// A group topic belongs to no assistant, so it paints no assistant artwork.
///
/// This is the fourth consumer of "who owns the open chat": the sidebar list,
/// the owner highlight and the fallback assistant are the other three.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a group topic paints no assistant artwork', (tester) async {
    await tester.runAsync(() async {
      final business = createBusinessTestPreferencesWithDatabase();
      final assistantPrefs = createBusinessTestPreferences();
      await assistantPrefs.load();
      await assistantPrefs.setString(
        'assistants_v1',
        jsonEncode([
          {
            'id': 'wall',
            'name': 'Wall',
            'background': 'https://example.com/wallpaper.png',
          },
        ]),
      );
      final assistants = AssistantProvider(preferences: assistantPrefs);
      await assistants.loaded;
      final assistantId = assistants.currentAssistantId!;
      final groups = GroupChatProvider(
        store: ExtensionEntityStore(business.database),
      );
      await groups.loaded;
      final group = await groups.create(name: 'G', memberIds: [assistantId]);
      final settings = SettingsProvider(createBusinessTestPreferences());
      await settings.loaded;

      Future<ChatBackdropSpec> specFor(Conversation open) async {
        late ChatBackdropSpec spec;
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<ChatService>.value(value: _Chat(open)),
              ChangeNotifierProvider<AssistantProvider>.value(
                value: assistants,
              ),
              ChangeNotifierProvider<GroupChatProvider>.value(value: groups),
              ChangeNotifierProvider<SettingsProvider>.value(value: settings),
            ],
            child: MaterialApp(
              home: Builder(
                builder: (context) {
                  spec = ChatBackdropSpec.resolve(context);
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        );
        return spec;
      }

      // The assistant owns a wallpaper, so an ordinary chat of theirs is
      // "active" — that is what makes the group case falsifiable.
      final groupTopic = Conversation(
        title: 'topic',
        extras: {Conversation.groupChatIdKey: group.id},
      );
      final groupSpec = await specFor(groupTopic);
      expect(groupSpec.active, isFalse);
      expect(groupSpec.useGradientBackground, isFalse);
      expect(groupSpec.backgroundRaw, isEmpty);

      final orphanTopic = Conversation(
        title: 'orphan',
        extras: {Conversation.groupChatIdKey: 'deleted-group'},
      );
      final orphanSpec = await specFor(orphanTopic);
      // A topic whose group is gone is an ordinary conversation: it paints like
      // one instead of disappearing into the group rule.
      expect(orphanSpec.active, isTrue);
    });
  });
}

class _Chat extends ChatService {
  _Chat(this.conversation);

  final Conversation conversation;

  @override
  String? get currentConversationId => conversation.id;

  @override
  Conversation? getConversation(String id) =>
      id == conversation.id ? conversation : null;
}
