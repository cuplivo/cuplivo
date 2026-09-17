import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/core/models/group_chat_conversations.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/utils/sandbox_path_resolver.dart';
import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  late Directory tempDir;
  late AppDatabase database;
  late ChatDatabaseRepository repository;
  late ChatService chatService;
  late GroupChatProvider provider;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('kelivo_gcp_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SandboxPathResolver.debugSetDirs(
      docsDir: tempDir.path,
      supportDir: tempDir.path,
    );
    SharedPreferences.setMockInitialValues({});
    database = AppDatabase(NativeDatabase.memory());
    repository = ChatDatabaseRepository(database);
    chatService = ChatService(existingRepository: repository);
    await chatService.init();
    provider = GroupChatProvider(chatService: chatService);
    await provider.load();
  });

  tearDown(() async {
    await chatService.close();
    await database.close();
    SandboxPathResolver.debugSetDirs(docsDir: null, supportDir: null);
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('createGroup', () {
    test(
      'creates conversation with group extras, group row, user member',
      () async {
        final group = await provider.createGroup(name: 'Team');
        expect(group.conversationId, isNotEmpty);
        expect(group.name, 'Team');
        expect(
          group.directorSystemPrompt,
          isNotEmpty,
          reason: 'default director prompt is set',
        );

        final conversation = chatService.getConversation(group.conversationId);
        expect(conversation, isNotNull);
        expect(
          GroupChatConversations.isGroupConversation(conversation!.extras),
          isTrue,
          reason: 'conversation carries the group kind marker',
        );

        final members = provider.membersOf(group.id);
        expect(members, hasLength(1));
        expect(members.single.isUser, isTrue);

        expect(provider.getById(group.id), isNotNull);
      },
    );
  });

  group('setMembers', () {
    test('user first, assistants deduped and ordered', () async {
      final group = await provider.createGroup(name: 'G');
      await provider.setMembers(group.id, ['b', 'a', 'b']);
      final ids = provider.assistantIdsOf(group.id);
      expect(ids, ['b', 'a']);
      final members = provider.membersOf(group.id);
      expect(members.first.isUser, isTrue);
      expect(members.where((m) => !m.isUser), hasLength(2));
    });

    test('hard cap rejects more than 20 assistants', () async {
      final group = await provider.createGroup(name: 'G');
      final many = List.generate(21, (i) => 'a$i');
      await expectLater(provider.setMembers(group.id, many), throwsStateError);
    });
  });

  group('addAssistants / removeAssistant', () {
    test('merges without duplicates and removes only the target', () async {
      final group = await provider.createGroup(name: 'G');
      await provider.setMembers(group.id, ['a1']);
      await provider.addAssistants(group.id, ['a1', 'a2']);
      expect(provider.assistantIdsOf(group.id), ['a1', 'a2']);

      await provider.removeAssistant(group.id, 'a1');
      expect(provider.assistantIdsOf(group.id), ['a2']);
    });
  });

  group('queued input stash', () {
    test('stash / take / has roundtrip clears the slot', () async {
      final group = await provider.createGroup(name: 'G');
      final input = ChatInputData(text: 'pending');
      expect(provider.hasQueuedInput(group.id), isFalse);

      provider.stashQueuedInput(group.id, input);
      expect(provider.hasQueuedInput(group.id), isTrue);

      final taken = provider.takeQueuedInput(group.id);
      expect(taken?.text, 'pending');
      expect(provider.hasQueuedInput(group.id), isFalse);
      expect(provider.takeQueuedInput(group.id), isNull);
    });
  });

  group('persistGroupState', () {
    test('round fields roundtrip through the repository', () async {
      final group = await provider.createGroup(name: 'G');
      final updated = group.copyWith(
        assistantMessagesThisRound: 2,
        pendingCapAssistantMessageId: 'msg-x',
      );
      await provider.persistGroupState(updated);

      final reloaded = provider.getById(group.id);
      expect(reloaded!.assistantMessagesThisRound, 2);
      expect(reloaded.pendingCapAssistantMessageId, 'msg-x');
    });
  });

  group('duplicateGroup', () {
    test(
      'copies config into a fresh conversation with runtime reset',
      () async {
        final group = await provider.createGroup(name: 'G');
        await provider.setMembers(group.id, ['a1', 'a2']);
        await provider.persistGroupState(
          group.copyWith(
            assistantMessagesThisRound: 2,
            pendingCapAssistantMessageId: 'msg-x',
          ),
        );

        final copy = await provider.duplicateGroup(group);
        expect(copy.id, isNot(group.id));
        expect(copy.conversationId, isNot(group.conversationId));
        expect(copy.assistantMessagesThisRound, 0);
        expect(copy.pendingCapAssistantMessageId, isNull);
        expect(provider.assistantIdsOf(copy.id), ['a1', 'a2']);
      },
    );
  });

  group('deleteGroup', () {
    test('removes the group row and its conversation', () async {
      final group = await provider.createGroup(name: 'G');
      expect(provider.getById(group.id), isNotNull);

      await provider.deleteGroup(group.id);

      expect(provider.getById(group.id), isNull);
      expect(chatService.getConversation(group.conversationId), isNull);
    });
  });
}
