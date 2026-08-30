import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
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

/// ChatService initialized over a real SQLite file (restore paths need an
/// initialized service with repo-backed state and the sync connection open).
class _FileBackedChatService extends ChatService {
  _FileBackedChatService();

  @override
  bool get initialized => _initializedOverride;

  bool _initializedOverride = false;

  /// The real [ChatService]._initialized is private; mark it set after
  /// [init] so restore paths see an initialized service but rely on the real
  /// repo + sync connection.
  Future<void> initForTest() async {
    await init();
    _initializedOverride = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  final services = <_FileBackedChatService>[];

  setUp(() async {
    businessPrefs = BusinessPreferences.memoryForTests();
    root = await Directory.systemTemp.createTemp('cuplivo_jsonl_test_');
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

  test(
    'JSONL backup round-trips conversations, messages and inline events',
    () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'theme_mode_v1': 'light',
      });
      final chatService = await createService();

      final conv = Conversation(
        id: 'jsonl-conv',
        title: 'JSONL round trip',
        assistantId: 'a1',
        messageIds: const ['m-user', 'm-assistant'],
      );
      final userMsg = ChatMessage(
        id: 'm-user',
        role: 'user',
        content: 'help me',
        conversationId: conv.id,
      );
      final assistantMsg = ChatMessage(
        id: 'm-assistant',
        role: 'assistant',
        content: 'sure',
        conversationId: conv.id,
      );
      await chatService.repo.putConversation(conv);
      await chatService.repo.putMessage(userMsg, messageOrder: 0);
      await chatService.repo.putMessage(assistantMsg, messageOrder: 1);
      await chatService.setToolEvents('m-assistant', [
        {'name': 'read_memory', 'args': '{}', 'result': 'ok'},
      ]);
      // repo.putMessage bypasses the cache; refresh so _exportChatsToFile's
      // getMessages sees the seeded messages.
      await chatService.reloadCachesFromDb();

      final sync = DataSync(
        preferences: businessPrefs,
        chatService: chatService,
      );
      final backupFile = await sync.prepareBackupFile(
        const WebDavConfig(content: BackupContentScope(chatsAndAssistants: true, attachments: false, workspaces: false, fontsAndAvatars: false, settings: true, skills: true)),
      );
      addTearDown(() => DataSync.cleanupTemporaryBackupFile(backupFile));

      final archive = ZipDecoder().decodeBytes(backupFile.readAsBytesSync());
      try {
        final meta = archive.findFile('chats_meta.json');
        expect(meta, isNotNull);
        expect(
          jsonDecode(utf8.decode(meta!.readBytes()!))['format_version'],
          2,
        );
        expect(archive.findFile('conversations.jsonl'), isNotNull);
        expect(archive.findFile('messages.jsonl'), isNotNull);
        expect(archive.findFile('chats.json'), isNull);
        // settings_meta only exists when the KV table carries timestamps.
        final settingsMeta = archive.findFile('settings_meta.json');
        expect(settingsMeta, isNotNull);
      } finally {
        archive.clearSync();
      }

      // Restore into a NEW service.
      final restoreService = await createService();
      final restoreSync = DataSync(
        preferences: businessPrefs,
        chatService: restoreService,
      );
      await restoreSync.restoreFromLocalFile(
        backupFile,
        const WebDavConfig(content: BackupContentScope(chatsAndAssistants: true, attachments: false, workspaces: false, fontsAndAvatars: false, settings: true, skills: true)),
        mode: RestoreMode.overwrite,
      );
      await restoreService.reloadCachesFromDb();

      final convs = restoreService.getAllCompleteConversations();
      expect(convs, hasLength(1));
      expect(convs.single.title, 'JSONL round trip');
      final msgs = restoreService.getMessages(conv.id);
      expect(msgs, hasLength(2));
      expect(restoreService.getToolEvents('m-assistant'), hasLength(1));
      expect(
        restoreService.getToolEvents('m-assistant').single['name'],
        'read_memory',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('JSONL merge restore skips existing conversation and messages', () async {
    businessPrefs = BusinessPreferences.memoryForTests({});
    final localService = await createService();
    final localConv = Conversation(id: 'local', title: 'Local');
    await localService.repo.putConversation(localConv);
    await localService.repo.putMessage(
      ChatMessage(
        id: 'local-msg',
        role: 'user',
        content: 'local',
        conversationId: 'local',
      ),
      messageOrder: 0,
    );

    final zipFile = File('${root.path}/merge.zip');
    final encoder = ZipFileEncoder();
    encoder.create(zipFile.path);
    final settingsFile = File('${root.path}/settings.json');
    await settingsFile.writeAsString('{}');
    encoder.addFileSync(settingsFile, 'settings.json');
    final convsFile = File('${root.path}/conversations.jsonl');
    await convsFile.writeAsString(
      '${jsonEncode({'conversation': Conversation(id: 'remote', title: 'Remote').toJson()})}\n',
    );
    encoder.addFileSync(convsFile, 'conversations.jsonl');
    final msgsFile = File('${root.path}/messages.jsonl');
    await msgsFile.writeAsString(
      '${jsonEncode({'message': ChatMessage(id: 'remote-msg', role: 'user', content: 'remote', conversationId: 'remote').toJson()})}\n',
    );
    encoder.addFileSync(msgsFile, 'messages.jsonl');
    final metaFile = File('${root.path}/chats_meta.json');
    await metaFile.writeAsString(
      jsonEncode({
        'format_version': 2,
        'tables': ['conversations', 'messages'],
        'conversation_count': 1,
        'message_count': 1,
        'groupChats': <dynamic>[],
        'groupMembers': <dynamic>[],
      }),
    );
    encoder.addFileSync(metaFile, 'chats_meta.json');
    encoder.closeSync();

    final sync = DataSync(
      preferences: businessPrefs,
      chatService: localService,
    );
    await sync.restoreFromLocalFile(
      zipFile,
      const WebDavConfig(content: BackupContentScope(chatsAndAssistants: true, attachments: false, workspaces: false, fontsAndAvatars: false, settings: true, skills: true)),
      mode: RestoreMode.merge,
    );

    final convs = localService.getAllCompleteConversations();
    expect(convs, hasLength(2));
    expect(convs.map((c) => c.id), containsAll(['local', 'remote']));
    expect(localService.getMessages('remote'), hasLength(1));
    expect(localService.getMessages('local'), hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('LWW scalar merge: newer backup wins, older keeps local', () async {
    businessPrefs = BusinessPreferences.memoryForTests({});
    final prefs = businessPrefs;
    // Local theme_mode_v1 updated at 1000; local theme_palette_v1 at 2000.
    await prefs.store.write('theme_mode_v1', 'dark', updatedAt: 1000);
    await prefs.store.write('theme_palette_v1', 'forest', updatedAt: 2000);
    await prefs.reload();

    final zipFile = File('${root.path}/lww.zip');
    final encoder = ZipFileEncoder();
    encoder.create(zipFile.path);
    final settingsFile = File('${root.path}/settings.json');
    await settingsFile.writeAsString(
      jsonEncode({'theme_mode_v1': 'light', 'theme_palette_v1': 'ocean'}),
    );
    encoder.addFileSync(settingsFile, 'settings.json');
    final metaFile = File('${root.path}/settings_meta.json');
    await metaFile.writeAsString(
      jsonEncode({'theme_mode_v1': 3000, 'theme_palette_v1': 500}),
    );
    encoder.addFileSync(metaFile, 'settings_meta.json');
    // Flush the facade's write tail (setString is serialized; restore reads
    // through the same instance, so ordering is safe, but flush anyway).
    await prefs.flushPendingWrites();
    encoder.closeSync();

    final chatService = await createService();
    final sync = DataSync(preferences: businessPrefs, chatService: chatService);
    await sync.restoreFromLocalFile(
      zipFile,
      const WebDavConfig(content: BackupContentScope(chatsAndAssistants: false, attachments: false, workspaces: false, fontsAndAvatars: false, settings: true, skills: true)),
      mode: RestoreMode.merge,
    );

    expect(
      prefs.getString('theme_mode_v1'),
      'light',
      reason: 'newer backup wins',
    );
    expect(
      prefs.getString('theme_palette_v1'),
      'forest',
      reason: 'older backup loses to local',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'kelivoLegacy format ships a version-1 chats.json and no jsonl streams',
    () async {
      businessPrefs = BusinessPreferences.memoryForTests({
        'theme_mode_v1': 'light',
      });
      final chatService = await createService();
      final conv = Conversation(id: 'legacy-conv', title: 'Legacy');
      await chatService.repo.putConversation(conv);
      await chatService.repo.putMessage(
        ChatMessage(
          id: 'legacy-msg',
          role: 'assistant',
          content: 'hi',
          conversationId: 'legacy-conv',
        ),
        messageOrder: 0,
      );
      await chatService.setToolEvents('legacy-msg', [
        {'name': 'read_memory', 'args': '{}', 'result': 'ok'},
      ]);
      await chatService.reloadCachesFromDb();

      final sync = DataSync(
        preferences: businessPrefs,
        chatService: chatService,
      );
      final backupFile = await sync.prepareBackupFile(
        const WebDavConfig(content: BackupContentScope(chatsAndAssistants: true, attachments: false, workspaces: false, fontsAndAvatars: false, settings: true, skills: true)),
        format: BackupFormat.kelivoLegacy,
      );
      addTearDown(() => DataSync.cleanupTemporaryBackupFile(backupFile));

      final archive = ZipDecoder().decodeBytes(backupFile.readAsBytesSync());
      try {
        expect(archive.findFile('chats.json'), isNotNull);
        expect(archive.findFile('chats_meta.json'), isNull);
        expect(archive.findFile('conversations.jsonl'), isNull);
        expect(archive.findFile('messages.jsonl'), isNull);
        // No LWW companion in the legacy format either — Kelivo ignores it,
        // and the format is meant to be maximally close to v1.
        expect(archive.findFile('settings_meta.json'), isNull);

        final chatsEntry = archive.findFile('chats.json')!;
        final chats =
            jsonDecode(utf8.decode(chatsEntry.readBytes()!))
                as Map<String, dynamic>;
        expect(chats['version'], 1);
        expect((chats['conversations'] as List), hasLength(1));
        final msgs = (chats['messages'] as List).cast<Map>();
        expect(msgs, hasLength(1));
        expect(msgs.single['id'], 'legacy-msg');
        expect(chats['toolEvents'], isNotEmpty);
        expect(chats['groupChats'], isEmpty);
      } finally {
        archive.clearSync();
      }

      // Self round-trip: a legacy zip must restore via the legacy chats.json
      // path (sentinel absent → legacy branch).
      final restoreService = await createService();
      final restoreSync = DataSync(
        preferences: businessPrefs,
        chatService: restoreService,
      );
      await restoreSync.restoreFromLocalFile(
        backupFile,
        const WebDavConfig(content: BackupContentScope(chatsAndAssistants: true, attachments: false, workspaces: false, fontsAndAvatars: false, settings: true, skills: true)),
        mode: RestoreMode.overwrite,
      );
      await restoreService.reloadCachesFromDb();
      expect(restoreService.getAllCompleteConversations(), hasLength(1));
      expect(restoreService.getMessages('legacy-conv'), hasLength(1));
      expect(restoreService.getToolEvents('legacy-msg'), hasLength(1));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
