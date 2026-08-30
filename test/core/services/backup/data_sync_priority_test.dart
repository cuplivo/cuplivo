import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/backup.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

class _FileBackedChatService extends ChatService {
  _FileBackedChatService();

  @override
  bool get initialized => _initializedOverride;

  bool _initializedOverride = false;

  Future<void> initForTest() async {
    await init();
    _initializedOverride = true;
  }
}

/// Builds a minimal JSONL sync zip: a wrapper the direction tests use to hand
/// the restore a fixed payload (settings + chats) without any export step.
Future<File> _buildJsonlZip({
  required String root,
  required Map<String, dynamic> settings,
  Map<String, int>? settingsMeta,
  List<Conversation> conversations = const [],
  List<ChatMessage> messages = const [],
}) async {
  final zipFile = File('$root/direction.zip');
  final encoder = ZipFileEncoder();
  encoder.create(zipFile.path);

  final settingsFile = File('$root/settings.json');
  await settingsFile.writeAsString(jsonEncode(settings));
  encoder.addFileSync(settingsFile, 'settings.json');

  if (settingsMeta != null) {
    final metaFile = File('$root/settings_meta.json');
    await metaFile.writeAsString(jsonEncode(settingsMeta));
    encoder.addFileSync(metaFile, 'settings_meta.json');
  }

  final convsFile = File('$root/conversations.jsonl');
  await convsFile.writeAsString(
    conversations
        .map((c) => jsonEncode({'conversation': c.toJson()}))
        .join('\n'),
  );
  encoder.addFileSync(convsFile, 'conversations.jsonl');

  final msgsFile = File('$root/messages.jsonl');
  await msgsFile.writeAsString(
    messages.map((m) => jsonEncode({'message': m.toJson()})).join('\n'),
  );
  encoder.addFileSync(msgsFile, 'messages.jsonl');

  final metaFile = File('$root/chats_meta.json');
  await metaFile.writeAsString(
    jsonEncode({
      'format_version': 2,
      'tables': ['conversations', 'messages'],
      'conversation_count': conversations.length,
      'message_count': messages.length,
      'groupChats': <dynamic>[],
      'groupMembers': <dynamic>[],
    }),
  );
  encoder.addFileSync(metaFile, 'chats_meta.json');

  encoder.closeSync();
  return zipFile;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  final services = <_FileBackedChatService>[];

  setUp(() async {
    businessPrefs = BusinessPreferences.memoryForTests();
    root = await Directory.systemTemp.createTemp('cuplivo_priority_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
  });

  tearDown(() async {
    for (final service in services) {
      await service.close();
    }
    services.clear();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<_FileBackedChatService> createService() async {
    final service = _FileBackedChatService();
    await service.initForTest();
    services.add(service);
    return service;
  }

  group('Assistants direction (category A)', () {
    /// Local: a1 "PC Assistent". Incoming: a1 "Phone Assistent" + unique a2.
    Future<File> assistantZip() => _buildJsonlZip(
      root: root.path,
      settings: {
        'assistants_v1': jsonEncode([
          Assistant(id: 'a1', name: 'Phone Assistent').toJson(),
          Assistant(id: 'a2', name: 'Phone Only').toJson(),
        ]),
      },
    );

    test(
      'auto = incoming wins by field (incumbent), exclusives merge in',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({});
        final service = await createService();
        await service.reloadCachesFromDb();
        await service.putAssistants([
          Assistant(id: 'a1', name: 'PC Assistent'),
        ]);

        final sync = DataSync(preferences: businessPrefs, chatService: service);
        await sync.restoreFromLocalFile(
          await assistantZip(),
          const WebDavConfig(includeChats: true, includeFiles: false),
          mode: RestoreMode.merge,
        );

        final assistants = await service.getAllAssistants();
        expect(assistants, hasLength(2));
        final a1 = assistants.firstWhere((a) => a.id == 'a1');
        expect(a1.name, 'Phone Assistent', reason: 'auto keeps incoming-wins');
        expect(
          assistants.map((a) => a.id),
          contains('a2'),
          reason: 'exclusive incoming assistant still merges',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'localWins keeps the local copy and still merges exclusives',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({});
        final service = await createService();
        await service.reloadCachesFromDb();
        await service.putAssistants([
          Assistant(id: 'a1', name: 'PC Assistent'),
        ]);

        final sync = DataSync(preferences: businessPrefs, chatService: service);
        await sync.restoreFromLocalFile(
          await assistantZip(),
          const WebDavConfig(includeChats: true, includeFiles: false),
          mode: RestoreMode.merge,
          precedence: ConflictPrecedence.localWins,
        );

        final assistants = await service.getAllAssistants();
        expect(assistants, hasLength(2));
        final a1 = assistants.firstWhere((a) => a.id == 'a1');
        expect(a1.name, 'PC Assistent', reason: 'localWins beats incoming');
        expect(assistants.map((a) => a.id), contains('a2'));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('Conversation metadata direction (category D)', () {
    Conversation localConv() => Conversation(
      id: 'shared',
      title: 'Local Title',
      createdAt: DateTime(2020),
      updatedAt: DateTime(2020),
      messageIds: const ['local-msg'],
    );

    Future<File> directionZip() => _buildJsonlZip(
      root: root.path,
      settings: const {},
      conversations: [
        Conversation(
          id: 'shared',
          title: 'Remote Title',
          updatedAt: DateTime(2021),
          messageIds: const ['shared-msg', 'local-msg'],
        ),
      ],
      messages: [
        ChatMessage(
          id: 'shared-msg',
          role: 'user',
          content: 'remote',
          conversationId: 'shared',
        ),
        ChatMessage(
          id: 'local-msg',
          role: 'user',
          content: 'original',
          conversationId: 'shared',
        ),
      ],
    );

    Future<_FileBackedChatService> seeded() async {
      final service = await createService();
      await service.reloadCachesFromDb();
      await service.repo.putConversation(localConv());
      await service.repo.putMessage(
        ChatMessage(
          id: 'local-msg',
          role: 'user',
          content: 'original',
          conversationId: 'shared',
        ),
        messageOrder: 0,
      );
      await service.reloadCachesFromDb();
      return service;
    }

    test(
      'auto keeps local metadata (ID-skip) but still unions messages',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({});
        final service = await seeded();
        final sync = DataSync(preferences: businessPrefs, chatService: service);
        await sync.restoreFromLocalFile(
          await directionZip(),
          const WebDavConfig(includeChats: true, includeFiles: false),
          mode: RestoreMode.merge,
        );

        final conv = service.getAllCompleteConversations().firstWhere(
          (c) => c.id == 'shared',
        );
        expect(conv.title, 'Local Title');
        expect(
          conv.updatedAt.isAfter(DateTime(2021)),
          isTrue,
          reason:
              'auto keeps the local row but the updatedAt rider (issue #545) '
              'bumps it past the newest incoming message',
        );
        expect(
          service.getMessages('shared').map((m) => m.id),
          containsAll(['local-msg', 'shared-msg']),
          reason: 'message union preserved in auto mode',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('localWins keeps metadata and unions messages', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final service = await seeded();
      final sync = DataSync(preferences: businessPrefs, chatService: service);
      await sync.restoreFromLocalFile(
        await directionZip(),
        const WebDavConfig(includeChats: true, includeFiles: false),
        mode: RestoreMode.merge,
        precedence: ConflictPrecedence.localWins,
      );

      final conv = service.getAllCompleteConversations().firstWhere(
        (c) => c.id == 'shared',
      );
      expect(conv.title, 'Local Title');
      expect(
        service.getMessages('shared').map((m) => m.id),
        containsAll(['local-msg', 'shared-msg']),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('incomingWins replaces the row (13 fields) exempting id/createdAt/'
        'messageIds, union survives', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final service = await seeded();
      final sync = DataSync(preferences: businessPrefs, chatService: service);
      await sync.restoreFromLocalFile(
        await directionZip(),
        const WebDavConfig(includeChats: true, includeFiles: false),
        mode: RestoreMode.merge,
        precedence: ConflictPrecedence.incomingWins,
      );

      final convs = service.getAllCompleteConversations();
      expect(convs, hasLength(1));
      final conv = convs.single;
      expect(conv.id, 'shared');
      expect(conv.createdAt, DateTime(2020), reason: 'createdAt exempt');
      expect(conv.title, 'Remote Title');
      expect(
        conv.updatedAt.isAfter(DateTime(2021)),
        isTrue,
        reason:
            'winner row wins, then the updatedAt rider lifts it past the '
            'newest incoming message (max(winner, incoming msgs))',
      );
      expect(
        conv.messageIds,
        containsAll(['local-msg', 'shared-msg']),
        reason: 'messageIds is the union (loser exclusive survives)',
      );
      final msgs = service.getMessages('shared');
      expect(msgs.map((m) => m.id), containsAll(['local-msg', 'shared-msg']));
      expect(msgs, hasLength(2));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('incomingWins never regresses updatedAt below local activity', () async {
      // Losing side holds newer local activity (updatedAt 2023); the winning
      // row is from a stale peer (2021) and its exclusive message is 2022.
      // After the replace, the rider alone would lift to 2022 — the max rule
      // must keep the sort key at 2023 (the #545 sink would otherwise return).
      businessPrefs = BusinessPreferences.memoryForTests({});
      final service = await createService();
      await service.reloadCachesFromDb();
      await service.repo.putConversation(
        Conversation(
          id: 'shared',
          title: 'Local Title',
          createdAt: DateTime(2020),
          updatedAt: DateTime(2023),
          messageIds: const ['local-msg'],
        ),
      );
      await service.repo.putMessage(
        ChatMessage(
          id: 'local-msg',
          role: 'user',
          content: 'original',
          conversationId: 'shared',
        ),
        messageOrder: 0,
      );
      await service.reloadCachesFromDb();

      final zipFile = await _buildJsonlZip(
        root: root.path,
        settings: const {},
        conversations: [
          Conversation(
            id: 'shared',
            title: 'Remote Title',
            updatedAt: DateTime(2021),
          ),
        ],
        messages: [
          ChatMessage(
            id: 'shared-msg',
            role: 'user',
            content: 'remote',
            conversationId: 'shared',
            timestamp: DateTime(2022),
          ),
        ],
      );

      final sync = DataSync(preferences: businessPrefs, chatService: service);
      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(includeChats: true, includeFiles: false),
        mode: RestoreMode.merge,
        precedence: ConflictPrecedence.incomingWins,
      );

      final conv = service.getAllCompleteConversations().firstWhere(
        (c) => c.id == 'shared',
      );
      expect(
        conv.updatedAt.isAfter(DateTime(2022)),
        isTrue,
        reason:
            'max(winner row, local updatedAt): the losing side newer activity '
            'must not sink the sort key',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('updatedAt rider (issue #545 symptom 2)', () {
    test('merge append bumps stale conversation.updatedAt to the newest '
        'incoming message', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final service = await createService();
      await service.reloadCachesFromDb();
      await service.repo.putConversation(
        Conversation(
          id: 'old',
          title: 'Stale',
          updatedAt: DateTime(2020),
          messageIds: const ['old-msg'],
        ),
      );
      await service.repo.putMessage(
        ChatMessage(
          id: 'old-msg',
          role: 'user',
          content: 'old',
          conversationId: 'old',
        ),
        messageOrder: 0,
      );
      await service.reloadCachesFromDb();

      final zipFile = await _buildJsonlZip(
        root: root.path,
        settings: const {},
        conversations: [
          Conversation(id: 'old', title: 'Stale', updatedAt: DateTime(2020)),
        ],
        messages: [
          ChatMessage(
            id: 'new-msg',
            role: 'user',
            content: 'new',
            conversationId: 'old',
            timestamp: DateTime(2026),
          ),
        ],
      );

      final sync = DataSync(preferences: businessPrefs, chatService: service);
      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(includeChats: true, includeFiles: false),
        mode: RestoreMode.merge,
      );

      final conv = service.getAllCompleteConversations().firstWhere(
        (c) => c.id == 'old',
      );
      expect(
        conv.updatedAt.isAfter(DateTime(2025)),
        isTrue,
        reason:
            'rider: updatedAt must not stay stale after merging newer '
            'messages',
      );
      expect(service.getMessages('old'), hasLength(2));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('Scalar settings direction (category B)', () {
    /// local theme_mode_v1 dark @2000; backup light @1000 (older than local).
    Future<File> olderBackupZip() => _buildJsonlZip(
      root: root.path,
      settings: {'theme_mode_v1': 'light'},
      settingsMeta: {'theme_mode_v1': 1000},
    );

    test(
      'incomingWins overrides LWW even when the backup copy is older',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({});
        final prefs = businessPrefs;
        await prefs.store.write('theme_mode_v1', 'dark', updatedAt: 2000);
        await prefs.reload();
        await prefs.flushPendingWrites();

        final chatService = await createService();
        final sync = DataSync(
          preferences: businessPrefs,
          chatService: chatService,
        );
        await sync.restoreFromLocalFile(
          await olderBackupZip(),
          const WebDavConfig(includeChats: false, includeFiles: false),
          mode: RestoreMode.merge,
          precedence: ConflictPrecedence.incomingWins,
        );

        expect(
          prefs.getString('theme_mode_v1'),
          'light',
          reason: 'direction beats the clock',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('localWins keeps local even when the backup copy is newer', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final prefs = businessPrefs;
      await prefs.store.write('theme_mode_v1', 'dark', updatedAt: 1000);
      await prefs.reload();
      await prefs.flushPendingWrites();

      final zipFile = await _buildJsonlZip(
        root: root.path,
        settings: {'theme_mode_v1': 'light'},
        settingsMeta: {'theme_mode_v1': 3000},
      );

      final chatService = await createService();
      final sync = DataSync(
        preferences: businessPrefs,
        chatService: chatService,
      );
      await sync.restoreFromLocalFile(
        zipFile,
        const WebDavConfig(includeChats: false, includeFiles: false),
        mode: RestoreMode.merge,
        precedence: ConflictPrecedence.localWins,
      );

      expect(
        prefs.getString('theme_mode_v1'),
        'dark',
        reason: 'localWins keeps the local value despite newer backup meta',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
