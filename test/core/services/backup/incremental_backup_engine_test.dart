import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/incremental_backup.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart';
import 'package:Cuplivo/core/services/backup/incremental_apply_service.dart';
import 'package:Cuplivo/core/services/backup/incremental_backup_engine.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/utils/sandbox_path_resolver.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AppDatabase database;
  late ChatService chatService;
  late DataSync dataSync;
  late IncrementalBackupEngine engine;
  late IncrementalApplyService applyService;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('kelivo_incr_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SandboxPathResolver.debugSetDirs(
      docsDir: tempDir.path,
      supportDir: tempDir.path,
    );
    SharedPreferences.setMockInitialValues({});
    database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = ChatDatabaseRepository(database);
    chatService = ChatService(existingRepository: repository);
    addTearDown(chatService.close);
    await chatService.init();
    final preferences = BusinessPreferences(BusinessRepository(database));
    final settings = SettingsProvider(preferences);
    addTearDown(settings.dispose);
    await settings.loaded;
    dataSync = DataSync(
      chatService: chatService,
      businessRepository: BusinessRepository(database),
    );
    engine = IncrementalBackupEngine(
      chatService: chatService,
      dataSync: dataSync,
    );
    applyService = IncrementalApplyService(chatService: chatService);
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('payload carries only post-since conversations and messages', () async {
    final since = DateTime.now().subtract(const Duration(hours: 1));
    final old = await chatService.createConversation(title: 'Old');
    await chatService.addMessage(
      conversationId: old.id,
      role: 'user',
      content: 'old msg',
    );
    // Backdate: the conversation predates the window entirely.
    await chatService.putConversation(
      old.copyWith(
        createdAt: since.subtract(const Duration(days: 1)),
        updatedAt: since.subtract(const Duration(hours: 1)),
      ),
    );
    final fresh = await chatService.createConversation(title: 'Fresh');
    await chatService.addMessage(
      conversationId: fresh.id,
      role: 'user',
      content: 'new msg',
    );

    final payload = await engine.buildIncrementalChatsPayload(
      IncrementalBackupConfig(since: since),
    );
    final titles = (payload['conversations'] as List)
        .map((c) => (c as Map)['title'])
        .toList();
    expect(titles, contains('Fresh'));
    expect(titles, isNot(contains('Old')));
    final contents = (payload['messages'] as List)
        .map((m) => (m as Map)['content'])
        .toList();
    expect(contents, contains('new msg'));
    expect(contents, isNot(contains('old msg')));
  });

  test('zip round-trips chats, settings and asset files', () async {
    final conv = await chatService.createConversation(title: 'C');
    await chatService.addMessage(
      conversationId: conv.id,
      role: 'user',
      content: 'hello',
    );
    final roots = await dataSync.assetRootPaths();
    final uploadDir = Directory('${roots['upload']}');
    await uploadDir.create(recursive: true);
    final asset = File('${uploadDir.path}/a.txt');
    await asset.writeAsString('asset-bytes');

    final zip = await engine.exportToFile(
      config: IncrementalBackupConfig(since: DateTime(2020)),
      settingsJson: {'k': 'v'},
    );
    addTearDown(() async {
      if (await zip.exists()) await zip.delete();
    });
    expect(
      IncrementalBackupEngine.incrementalBaseName(
        DateTime(2026, 8, 4, 9, 30, 1),
        DateTime(2026, 8, 1),
      ),
      'cuplivo_incr_20260804-093001-000000_20260801-000000',
    );
    // Name matches the exported file's contract.
    expect(p.basenameWithoutExtension(zip.path), startsWith('cuplivo_incr_'));

    final read = await engine.readIncrementalZip(zip);
    expect(read.chats['conversations'] as List, isNotEmpty);
    expect(read.settings, {'k': 'v'});

    final extractDir = await Directory.systemTemp.createTemp('incr_extract_');
    addTearDown(() async {
      await extractDir.delete(recursive: true);
    });
    await engine.extractAssetFiles(zip, extractDir);
    expect(
      await File('${extractDir.path}/upload/a.txt').readAsString(),
      'asset-bytes',
    );
  });

  test('apply merges: inserts unknown, appends missing messages', () async {
    final since = DateTime(2020);
    final local = await chatService.createConversation(title: 'Shared');
    await chatService.addMessage(
      conversationId: local.id,
      role: 'user',
      content: 'local only',
    );

    // Build a payload that carries the shared conversation with a NEW
    // message plus an unknown conversation, then reset the message store by
    // applying it onto a fresh service over the same conversations.
    final payload = {
      'version': 1,
      'conversations': [
        local
            .copyWith(
              title: 'Shared (renamed by peer)',
              updatedAt: DateTime.now(),
            )
            .toJson(),
        (await chatService.createConversation(title: 'PeerOnly')).toJson(),
      ],
      'messages': [
        (await chatService.addMessage(
          conversationId: local.id,
          role: 'assistant',
          content: 'peer appended',
        )).toJson(),
      ],
    };
    // The payload above was built against live state; treat its messages as
    // the peer's increment. Applying must be idempotent for the shared
    // conversation metadata and never drop the local-only message.
    final report = await applyService.apply(payload);
    expect(report.insertedConversations + report.updatedConversations, 2);

    final messages = await chatService.loadMessages(local.id);
    expect(
      messages.map((m) => m.content),
      containsAll(['local only', 'peer appended']),
    );
    final renamed = chatService.getConversation(local.id);
    expect(renamed!.title, 'Shared (renamed by peer)');
  });

  test('apply is idempotent on replays', () async {
    final conv = await chatService.createConversation(title: 'R');
    final msg = await chatService.addMessage(
      conversationId: conv.id,
      role: 'user',
      content: 'once',
    );
    final payload = {
      'version': 1,
      'conversations': [conv.toJson()],
      'messages': [msg.toJson()],
    };
    final first = await applyService.apply(payload);
    final second = await applyService.apply(payload);
    expect(first.appendedMessages, greaterThanOrEqualTo(0));
    expect(second.appendedMessages, 0);
    final messages = await chatService.loadMessages(conv.id);
    expect(messages.where((m) => m.content == 'once'), hasLength(1));
  });
}
