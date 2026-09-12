import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/backup.dart';
import 'package:Cuplivo/core/models/knowledge.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/knowledge/knowledge_store.dart';

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

class _InMemoryChatService extends ChatService {
  late final AppDatabase db;
  late final ChatDatabaseRepository _testRepo;

  _InMemoryChatService() {
    db = AppDatabase(NativeDatabase.memory());
    _testRepo = ChatDatabaseRepository(db);
  }

  @override
  bool get initialized => true;

  @override
  ChatDatabaseRepository get repo => _testRepo;

  @override
  Future<List<Assistant>> getAllAssistants() => _testRepo.getAllAssistants();

  @override
  Future<void> putAssistants(List<Assistant> list) =>
      _testRepo.putAssistants(list);

  @override
  Future<void> reloadCachesFromDb() async {}

  Future<void> closeDb() async {
    await _testRepo.close();
  }
}

const _knowledgeOnly = BackupContentScope(
  chatsAndAssistants: false,
  settings: false,
  attachments: false,
  workspaces: false,
  skills: false,
  fontsAndAvatars: false,
  knowledgeBase: true,
);

const _knowledgeOff = BackupContentScope(
  chatsAndAssistants: false,
  settings: false,
  attachments: false,
  workspaces: false,
  skills: false,
  fontsAndAvatars: false,
  knowledgeBase: false,
);

void main() {
  group('DataSync knowledge base', () {
    late Directory root;

    setUp(() async {
      businessPrefs = BusinessPreferences.memoryForTests();
      root = await Directory.systemTemp.createTemp('kelivo_kb_sync_test_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    Future<void> seed(
      _InMemoryChatService service, {
      String baseName = '中医',
    }) async {
      final store = KnowledgeStore(service.repo.db, businessPrefs);
      final now = DateTime(2026, 9, 10, 12);
      await store.upsertBase(
        KnowledgeBase(
          id: 'kb1',
          name: baseName,
          chunkSize: 64,
          chunkOverlap: 8,
          createdAt: now,
          updatedAt: now,
        ),
      );
      final content = List.generate(
        20,
        (i) => '段落 $i 中医药 body text',
      ).join('\n');
      await store.restoreDocument(
        KnowledgeDocument(
          id: 'd1',
          knowledgeBaseId: 'kb1',
          name: 'a.txt',
          sourceType: 'txt',
          content: content,
          contentHash: 'h1',
          charCount: content.length,
          importedAt: now,
        ),
        chunkSize: 64,
        chunkOverlap: 8,
      );
    }

    test('round-trips through export/restore and rebuilds chunks', () async {
      final source = _InMemoryChatService();
      addTearDown(source.closeDb);
      await seed(source);

      final zip = await DataSync(
        preferences: businessPrefs,
        chatService: source,
      ).prepareBackupFile(const WebDavConfig(content: _knowledgeOnly));

      final input = InputFileStream(zip.path);
      try {
        final archive = ZipDecoder().decodeStream(input);
        expect(archive.findFile('knowledge.jsonl'), isNotNull);
        archive.clearSync();
      } finally {
        input.closeSync();
      }

      final target = _InMemoryChatService();
      addTearDown(target.closeDb);
      await DataSync(
        preferences: businessPrefs,
        chatService: target,
      ).restoreFromLocalFile(
        zip,
        const WebDavConfig(content: _knowledgeOnly),
        mode: RestoreMode.overwrite,
      );

      final store = KnowledgeStore(target.repo.db, businessPrefs);
      expect((await store.getBase('kb1'))?.name, '中医');
      expect(await store.countDocuments('kb1'), 1);
      expect(await store.countChunks('kb1'), greaterThan(0));
      final hits = await store.search(baseIds: ['kb1'], query: '中医药');
      expect(hits, isNotEmpty);
      expect(hits.first.documentName, 'a.txt');

      await DataSync.cleanupTemporaryBackupFile(zip);
    });

    test(
      'knowledgeBase bit off exports no section and restores nothing',
      () async {
        final source = _InMemoryChatService();
        addTearDown(source.closeDb);
        await seed(source);

        final zip = await DataSync(
          preferences: businessPrefs,
          chatService: source,
        ).prepareBackupFile(const WebDavConfig(content: _knowledgeOff));

        final input = InputFileStream(zip.path);
        try {
          final archive = ZipDecoder().decodeStream(input);
          expect(archive.findFile('knowledge.jsonl'), isNull);
          archive.clearSync();
        } finally {
          input.closeSync();
        }

        final target = _InMemoryChatService();
        addTearDown(target.closeDb);
        await DataSync(
          preferences: businessPrefs,
          chatService: target,
        ).restoreFromLocalFile(
          zip,
          const WebDavConfig(content: _knowledgeOff),
          mode: RestoreMode.overwrite,
        );

        final store = KnowledgeStore(target.repo.db, businessPrefs);
        expect(await store.getAllBases(), isEmpty);

        await DataSync.cleanupTemporaryBackupFile(zip);
      },
    );

    test('merge restore is idempotent and keeps the local base', () async {
      final source = _InMemoryChatService();
      addTearDown(source.closeDb);
      await seed(source);

      final zip = await DataSync(
        preferences: businessPrefs,
        chatService: source,
      ).prepareBackupFile(const WebDavConfig(content: _knowledgeOnly));

      final target = _InMemoryChatService();
      addTearDown(target.closeDb);
      final store = KnowledgeStore(target.repo.db, businessPrefs);
      final now = DateTime(2026, 1, 1);
      await store.upsertBase(
        KnowledgeBase(id: 'kb1', name: 'Local', createdAt: now, updatedAt: now),
      );

      final sync = DataSync(preferences: businessPrefs, chatService: target);
      await sync.restoreFromLocalFile(
        zip,
        const WebDavConfig(content: _knowledgeOnly),
        mode: RestoreMode.merge,
      );

      // Local base row wins on id conflict; its documents are still restored.
      expect((await store.getBase('kb1'))?.name, 'Local');
      expect(await store.countDocuments('kb1'), 1);

      // Second merge must not duplicate.
      await sync.restoreFromLocalFile(
        zip,
        const WebDavConfig(content: _knowledgeOnly),
        mode: RestoreMode.merge,
      );
      expect(await store.countDocuments('kb1'), 1);
      expect(await store.countChunks('kb1'), greaterThan(0));

      await DataSync.cleanupTemporaryBackupFile(zip);
    });
  });
}
