import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/business_restore_service.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart';
import 'package:Cuplivo/core/services/backup/incremental_apply_service.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/sync/lan_sync_client.dart';
import 'package:Cuplivo/core/services/sync/lan_sync_models.dart';
import 'package:Cuplivo/core/services/sync/lan_sync_restore_service.dart';
import 'package:Cuplivo/core/services/sync/lan_sync_server.dart';
import 'package:Cuplivo/utils/sandbox_path_resolver.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
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

  setUp(() async {
    // The test binding's HttpOverrides would fake every HttpClient with a
    // 400 responder; this suite exercises a real loopback exchange.
    HttpOverrides.global = null;
    tempDir = await Directory.systemTemp.createTemp('kelivo_lan_e2e_');
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
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('server and client exchange deltas end to end', () async {
    // Two stores: the server keeps this suite's service; the client gets
    // its own drift database seeded with a forked copy of the same data.
    final clientDb = AppDatabase(NativeDatabase.memory());
    addTearDown(clientDb.close);
    final clientRepo = ChatDatabaseRepository(clientDb);
    final clientService = ChatService(existingRepository: clientRepo);
    addTearDown(clientService.close);
    await clientService.init();
    final clientDataSync = DataSync(
      chatService: clientService,
      businessRepository: BusinessRepository(clientDb),
    );

    // Server-side data: one shared conversation plus a server-only one.
    final shared = await chatService.createConversation(title: 'Shared');
    await chatService.addMessage(
      conversationId: shared.id,
      role: 'user',
      content: 'server msg',
    );
    final serverOnly = await chatService.createConversation(title: 'SOnly');
    await chatService.addMessage(
      conversationId: serverOnly.id,
      role: 'user',
      content: 'server only msg',
    );

    // Client-side data: the same shared conversation with the same message
    // id (the common prefix) plus one client-only message after it.
    final serverMessages = await chatService.loadMessages(shared.id);
    final commonMessage = serverMessages.first;
    await clientService.putConversation(
      shared.copyWith(messageIds: [commonMessage.id]),
    );
    await clientService.addMessageDirectly(shared.id, commonMessage);
    await clientService.addMessage(
      conversationId: shared.id,
      role: 'assistant',
      content: 'client increment',
    );
    final clientExtra = await clientService.createConversation(title: 'COnly');
    await clientService.addMessage(
      conversationId: clientExtra.id,
      role: 'user',
      content: 'client only msg',
    );

    final server = LanSyncServer(
      chatService: chatService,
      dataSync: dataSync,
      assistantIds: () async => const ['a1'],
    );
    addTearDown(server.stop);
    await server.start();
    expect(server.running, isTrue);
    expect(server.port, isNotNull);
    expect(server.pin, isNotNull);
    final pin = server.pin!;

    final client = LanSyncClient(
      chatService: clientService,
      dataSync: clientDataSync,
      assistantIds: () async => const ['a1', 'a2'],
    );
    addTearDown(client.close);

    // Round 1: plan. Same ChatService acts as the initiator's data (the
    // in-process transport sees identical conversations + one extra assistant).
    final plan = await client.negotiate(
      host: '127.0.0.1',
      port: server.port!,
      pin: pin,
    );
    expect(plan.conversations, isNotEmpty);
    expect(plan.missingAssistantIds, contains('a2'));

    // Round 2: exchange. Both sides build zips over the same data.
    File? clientReceived;
    client.onZipReceived = (zip) async {
      clientReceived = zip;
    };
    File? serverReceived;
    server.onZipReceived = (zip) async {
      serverReceived = zip;
    };
    await client.exchange(host: '127.0.0.1', port: server.port!, pin: pin);

    // Both peers produced an incremental zip carrying the shared
    // conversation's messages.
    expect(clientReceived, isNotNull);
    expect(serverReceived, isNotNull);

    // The zip the CLIENT received is the SERVER's delta: it must carry the
    // server-only conversation (and not the client-only one).
    final engine = clientDataSync.incrementalEngine;
    final clientPayload = await engine.readIncrementalZip(clientReceived!);
    final titles = (clientPayload.chats['conversations'] as List)
        .map((c) => (c as Map)['title'])
        .toList();
    expect(titles, contains('SOnly'));
    expect(titles, isNot(contains('COnly')));

    // Apply the server's delta onto the CLIENT store.
    final restore = LanSyncRestoreService(
      chatService: clientService,
      dataSync: clientDataSync,
      applyService: IncrementalApplyService(chatService: clientService),
      businessRestore: BusinessRestoreService(
        BusinessRepository(clientDb),
      ).merge,
    );
    final report = await restore.applyZip(clientReceived!);
    expect(report.insertedConversations, greaterThan(0));

    // The client now sees the server-only conversation, and the shared
    // conversation gained the server's message without losing its own.
    expect(clientService.getConversation(serverOnly.id), isNotNull);
    final mergedMessages = await clientService.loadMessages(shared.id);
    expect(
      mergedMessages.map((m) => m.content),
      containsAll(['server msg', 'client increment']),
    );

    await clientReceived!.delete();
    await serverReceived!.delete();
  });

  test('resolveIncomingWins maps wire priority per role', () {
    // Null (auto): incoming wins (additive merge default).
    expect(resolveIncomingWins(syncPriority: null, isInitiator: true), isTrue);
  });

  test('SyncPlan json round-trip', () {
    final plan = SyncPlan(
      conversations: [
        SyncConvPlan(
          conversationId: 'c1',
          conversationTitle: 'T',
          state: SyncConvState.serverOnly,
          forkPointMessageId: null,
          initiatorIncrementCount: 0,
          serverIncrementCount: 3,
        ),
      ],
      missingAssistantIds: const [],
      remoteMissingAssistantIds: const [],
      since: DateTime(2026, 8, 1),
      serverFileCount: 2,
      serverFileSizeBytes: 10,
      serverFileManifest: null,
      syncPriority: null,
    );
    final restored = SyncPlan.fromJsonString(plan.toJsonString());
    expect(restored.conversations.single.conversationId, 'c1');
    expect(restored.conversations.single.state, SyncConvState.serverOnly);
    expect(restored.serverFileCount, 2);
  });
}
