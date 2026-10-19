import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/recycle/recycle_service.dart';

import '../../support/business_preferences_test_harness.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

/// What deleting an assistant leaves in the bin.
///
/// The cascade removes conversations and then the assistant's own row, and the
/// bin must show that as the one act it was: every conversation the cascade
/// took carries the same group, and the assistant's entry — which rides the
/// generic list persistence rather than a delete call — sits next to them with
/// its own name. Both halves are asserted here because the group is only worth
/// anything if it names the thing the user actually deleted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late BusinessPreferencesTestHarness harness;
  late BusinessPreferencesTestSession session;
  late ChatService chatService;
  late AssistantProvider provider;
  late RecycleService recycle;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('kelivo_recycle_casc_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(directory.path);
    final bin = Directory('${directory.path}/bin');
    Future<Directory> binDirectory() async {
      if (!await bin.exists()) await bin.create(recursive: true);
      return bin;
    }

    harness = await BusinessPreferencesTestHarness.create();
    session = await harness.open(
      recycle: (database) => RecycleService(
        database,
        store: RecycleStore(directory: binDirectory),
      ),
    );
    recycle = session.recycle!;
    chatService = ChatService(
      existingRepository: ChatDatabaseRepository(
        session.database,
        recycle: recycle,
      ),
    );
    await chatService.init();
    await session.preferences.setString(
      'assistants_v1',
      jsonEncode(const [
        {'id': 'assistant-delete', 'name': 'Delete Me'},
        {'id': 'assistant-keep', 'name': 'Keep Me'},
      ]),
    );
    await session.preferences.setString(
      'current_assistant_id_v1',
      'assistant-delete',
    );
    provider = AssistantProvider(
      preferences: session.preferences,
      chatService: chatService,
    );
    // The provider's own future, not a timeout: a fixed poll budget is a flake
    // waiting for a loaded machine.
    await provider.loaded;
    expect(provider.assistants, hasLength(2));
  });

  tearDown(() async {
    // A detached bin write must finish before the directory holding it goes, or
    // the delete races the write's own file handle.
    await recycle.settle();
    await chatService.close();
    await harness.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  /// The bin writes after the operation that fed it, so an assertion lets that
  /// write finish first — otherwise "nothing was staged" and "the write has not
  /// started" are the same observation.
  Future<List<RecycleEntry>> binEntries() async {
    await recycle.settle();
    return recycle.list();
  }

  test(
    'a deleted assistant leaves one group holding its conversations',
    () async {
      final mine = <String>[];
      for (final title in ['First', 'Second', 'Third']) {
        final conversation = await chatService.createConversation(
          title: title,
          assistantId: 'assistant-delete',
        );
        mine.add(conversation.id);
        await chatService.addMessage(
          conversationId: conversation.id,
          role: 'user',
          content: 'message in $title',
        );
      }
      final kept = await chatService.createConversation(
        title: 'Kept',
        assistantId: 'assistant-keep',
      );

      expect(await provider.deleteAssistant('assistant-delete'), isTrue);

      final entries = await binEntries();
      final conversations = entries
          .where((entry) => entry.type == RecycleEntryType.conversation)
          .toList();
      expect(conversations.map((entry) => entry.key), unorderedEquals(mine));
      // One act, one group — and the group says which assistant caused it.
      final groupIds = conversations.map((entry) => entry.group?.id).toSet();
      expect(groupIds, hasLength(1));
      expect(groupIds.single, isNotNull);
      for (final entry in conversations) {
        expect(entry.group!.label, 'Delete Me');
      }
      // Every conversation kept its subtree, so the group is recoverable.
      for (final entry in conversations) {
        final tables = await recycle.readTables(entry);
        expect(tables!['message_rows'], hasLength(1));
      }

      final assistant = entries.singleWhere(
        (entry) => entry.type == RecycleEntryType.businessEntity,
      );
      expect(assistant.key, 'assistant-delete');
      expect(assistant.kindWire, 'assistant_rows');
      // The assistant's own entry is not in the group: its row is removed by the
      // list persistence, which a delete call cannot stamp.
      expect(assistant.group, isNull);

      expect(chatService.getConversation(kept.id), isNotNull);
      expect(entries.any((entry) => entry.key == kept.id), isFalse);
    },
  );

  test('a single conversation delete is nobody else\'s group', () async {
    final conversation = await chatService.createConversation(
      title: 'Alone',
      assistantId: 'assistant-delete',
    );

    await chatService.deleteConversation(conversation.id);

    final entry = (await binEntries()).single;
    expect(entry.type, RecycleEntryType.conversation);
    expect(entry.group, isNull);
  });
}
