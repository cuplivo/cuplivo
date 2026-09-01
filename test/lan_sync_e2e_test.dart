import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/backup.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/sync/lan_sync_client.dart';
import 'package:Cuplivo/core/services/sync/lan_sync_models.dart';
import 'package:Cuplivo/core/services/sync/lan_sync_server.dart';

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

/// Minimal ChatService fake: index-building surface real, backed by a
/// file-based Drift repo (getMessageIdsSync needs a sync connection).
/// The restore layer calls the public mutation surface below; they delegate
/// straight to the repo, bypassing the base CacheService internals whose
/// private fields (`_repo`, `_conversationsCache`) are populated by [init].
class _FakeChatService extends ChatService {
  _FakeChatService(this._repo);

  final ChatDatabaseRepository _repo;
  final List<Conversation> _conversations = [];

  @override
  ChatDatabaseRepository get repo => _repo;

  @override
  bool get initialized => true;

  @override
  List<Conversation> getAllCompleteConversations() => _conversations;

  @override
  List<ChatMessage> getMessages(String conversationId) {
    final count = _repo.getMessageCountSync(conversationId);
    return _repo.getMessagesRangeSync(conversationId, start: 0, limit: count);
  }

  @override
  Future<List<Assistant>> getAllAssistants() => _repo.getAllAssistants();
  @override
  Future<void> putAssistants(List<Assistant> list) async {
    debugPrint('[e2e] putAssistants: ${list.map((a) => a.name).toList()}');
    await _repo.putAssistants(list);
    debugPrint(
      '[e2e] putAssistants done: '
      '${(await _repo.getAllAssistants()).map((a) => a.name).toList()}',
    );
  }

  @override
  Future<void> putAssistant(Assistant a) => _repo.putAssistant(a);

  @override
  Future<void> addMessageDirectly(
    String conversationId,
    ChatMessage message,
  ) async {
    final skip = _repo.getMessageIdsSync(conversationId).contains(message.id);
    if (!skip) {
      await _repo.putMessage(message, messageOrder: 0);
    }
  }

  @override
  Future<void> replaceConversationRow(Conversation updated) async {
    await _repo.putConversation(updated);
  }

  @override
  Future<void> restoreConversationsBatch({
    required List<Conversation> conversations,
    required Map<String, List<ChatMessage>> messagesByConversation,
    required Map<String, List<Map<String, dynamic>>> toolEventsByMessageId,
    required Map<String, String> geminiSignaturesByMessageId,
  }) async {
    await _repo.putRestoreBatch(
      conversations: conversations,
      messagesByConversation: messagesByConversation,
      toolEventsByMessageId: toolEventsByMessageId,
      geminiSignaturesByMessageId: geminiSignaturesByMessageId,
    );
  }

  @override
  List<Map<String, dynamic>> getToolEvents(String assistantMessageId) {
    return const <Map<String, dynamic>>[];
  }

  @override
  Future<void> setToolEvents(
    String assistantMessageId,
    List<Map<String, dynamic>> events,
  ) {
    return _repo.setToolEvents(assistantMessageId, events);
  }

  @override
  String? getGeminiThoughtSignature(String assistantMessageId) => null;

  @override
  Future<void> setGeminiThoughtSignature(
    String assistantMessageId,
    String signature,
  ) {
    return _repo.setGeminiThoughtSignature(assistantMessageId, signature);
  }
}

/// One full "device" under test: its own repo, preferences and DataSync.
class _Device {
  _Device({
    required this.repo,
    required this.chatService,
    required this.dataSync,
    required this.preferences,
  });

  final ChatDatabaseRepository repo;
  final _FakeChatService chatService;
  final DataSync dataSync;
  final BusinessPreferences preferences;

  Future<Assistant?> assistant(String id) async {
    final all = await repo.getAllAssistants();
    for (final a in all) {
      if (a.id == id) return a;
    }
    return null;
  }
}

Future<_Device> _makeDevice(Directory root, String dbName) async {
  final dbFile = File('${root.path}${Platform.pathSeparator}$dbName');
  final repo = ChatDatabaseRepository.open(file: dbFile);
  await repo.ensureReady();
  final prefs = BusinessPreferences.memoryForTests({});
  final chatService = _FakeChatService(repo);
  final dataSync = DataSync(preferences: prefs, chatService: chatService);
  return _Device(
    repo: repo,
    chatService: chatService,
    dataSync: dataSync,
    preferences: prefs,
  );
}

/// The UI-side restore hook for each peer (mirrors `_restoreAndRestart` in
/// lan_sync_section.dart): merge-restore a received zip with the role
/// relative precedence for this session.
Future<void> _restoreZip(
  _Device device,
  File zipFile,
  SyncPriority? priority, {
  required bool isInitiator,
}) async {
  final precedence = resolveSyncPrecedence(priority, isInitiator: isInitiator);
  return device.dataSync.restoreFromLocalFile(
    zipFile,
    const WebDavConfig(),
    mode: RestoreMode.merge,
    precedence: precedence,
  );
}

/// Seeds both devices with an identical conversation (m1 + m2), plus one
/// extra message on exactly one side — the only chat delta in the session.
/// Assistant conflict (`a1` with different names) is written separately.
Future<void> _seedChats(
  _Device initiator,
  _Device server, {
  required bool initiatorHasExtra,
}) async {
  await initiator.repo.putConversation(Conversation(id: 'c1', title: 'Chat 1'));
  await server.repo.putConversation(Conversation(id: 'c1', title: 'Chat 1'));
  await initiator.repo.putMessage(
    ChatMessage(
      id: 'm1',
      role: 'user',
      content: 'hello 1',
      conversationId: 'c1',
      timestamp: DateTime(2025, 1, 1),
    ),
  );
  await server.repo.putMessage(
    ChatMessage(
      id: 'm1',
      role: 'user',
      content: 'hello 1',
      conversationId: 'c1',
      timestamp: DateTime(2025, 1, 1),
    ),
  );
  await initiator.repo.putMessage(
    ChatMessage(
      id: 'm2',
      role: 'user',
      content: 'hello 2',
      conversationId: 'c1',
      timestamp: DateTime(2025, 1, 2),
    ),
  );
  await server.repo.putMessage(
    ChatMessage(
      id: 'm2',
      role: 'user',
      content: 'hello 2',
      conversationId: 'c1',
      timestamp: DateTime(2025, 1, 2),
    ),
  );
  await (initiatorHasExtra ? initiator : server).repo.putMessage(
    ChatMessage(
      id: 'm_extra',
      role: 'user',
      content: 'extra',
      conversationId: 'c1',
      timestamp: DateTime(2025, 1, 3),
    ),
  );
  initiator.chatService._conversations.add(
    Conversation(id: 'c1', title: 'Chat 1'),
  );
  server.chatService._conversations.add(
    Conversation(id: 'c1', title: 'Chat 1'),
  );
}

/// Seeds both devices with an identical conversation + message list but
/// DIFFERENT row metadata (title / isPinned / summary) — the only delta in
/// the session is metadata (issue #615 category D). No assistants, no files.
Future<void> _seedMetadataConflictChats(
  _Device initiator,
  _Device server, {
  required String initiatorTitle,
  required String serverTitle,
}) async {
  final iRow = Conversation(
    id: 'c1',
    title: initiatorTitle,
    isPinned: true,
    summary: 'initiator summary',
  );
  final sRow = Conversation(id: 'c1', title: serverTitle, isPinned: false);
  await initiator.repo.putConversation(iRow);
  await server.repo.putConversation(sRow);
  for (final device in [initiator, server]) {
    await device.repo.putMessage(
      ChatMessage(
        id: 'm1',
        role: 'user',
        content: 'hello 1',
        conversationId: 'c1',
        timestamp: DateTime(2025, 1, 1),
      ),
    );
    await device.repo.putMessage(
      ChatMessage(
        id: 'm2',
        role: 'user',
        content: 'hello 2',
        conversationId: 'c1',
        timestamp: DateTime(2025, 1, 2),
      ),
    );
  }
  initiator.chatService._conversations.add(iRow);
  server.chatService._conversations.add(sRow);
}

Future<void> _closeDevice(_Device device) async {
  await device.repo.close();
}

void main() {
  // NOTE: no TestWidgetsFlutterBinding here on purpose — it stubs every
  // HttpClient with a 400 response, and this suite exercises the real
  // LAN HTTP protocol over loopback.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory tempDir;
  late Directory initiatorRoot;
  late Directory serverRoot;
  late PathProviderPlatform prevProvider;
  late _Device initiator;
  late _Device server;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cuplivo_lan_sync_e2e');
    initiatorRoot = Directory('${tempDir.path}/initiator');
    serverRoot = Directory('${tempDir.path}/server');
    await initiatorRoot.create(recursive: true);
    await serverRoot.create(recursive: true);
    initiator = await _makeDevice(initiatorRoot, 'initiator.db');
    server = await _makeDevice(serverRoot, 'server.db');

    prevProvider = PathProviderPlatform.instance;
    // Both devices share one provider and one empty file tree because this
    // suite uses chat deltas only; the manifest builders agree on both sides.
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    addTearDown(() => PathProviderPlatform.instance = prevProvider);
  });

  tearDown(() async {
    await _closeDevice(initiator);
    await _closeDevice(server);
    // Best-effort: WAL handles may still be released a tick after close.
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  test('e2e: server-only chat delta + initiatorWins converges both peers to '
      'the initiator settings (review round 2 scenario 1)', () async {
    await _seedChats(initiator, server, initiatorHasExtra: false);
    await initiator.repo.putAssistants([
      Assistant(id: 'a1', name: 'Initiator Assistant'),
    ]);
    await server.repo.putAssistants([
      Assistant(id: 'a1', name: 'Server Assistant'),
    ]);

    expect(initiator.repo.getMessageCountSync('c1'), 2);
    expect(server.repo.getMessageCountSync('c1'), 3);

    final lanServer = LanSyncServer(
      chatService: server.chatService,
      dataSync: server.dataSync,
    );
    await lanServer.start(preferredPort: 0);
    addTearDown(lanServer.stop);

    final lanClient = LanSyncClient(
      chatService: initiator.chatService,
      dataSync: initiator.dataSync,
    );
    addTearDown(lanClient.close);

    // The server restores AFTER the HTTP response closes — completing this
    // completer is the only way to observe that asynchronous restore from
    // the test before asserting (exchange() only awaits the client's own).
    final serverDone = Completer<void>();
    var serverRestored = false;
    lanServer.onZipReceived = (zip) async {
      try {
        await _restoreZip(
          server,
          zip,
          lanServer.initiatorPriority,
          isInitiator: false,
        );
      } catch (e) {
        if (!serverDone.isCompleted) serverDone.completeError(e);
        return;
      }
      serverRestored = true;
      debugPrint(
        '[e2e] scenario1 post-restore server assistants: '
        '${(await server.repo.getAllAssistants()).map((a) => a.name).toList()}',
      );
      if (!serverDone.isCompleted) serverDone.complete();
    };
    var clientRestored = false;
    lanClient.onZipReceived = (zip) async {
      await _restoreZip(
        initiator,
        zip,
        lanClient.effectivePriority,
        isInitiator: true,
      );
      clientRestored = true;
    };

    await lanClient.negotiate(
      host: '127.0.0.1',
      port: lanServer.port!,
      pin: lanServer.pin!,
      syncPriority: SyncPriority.initiatorWins,
    );
    expect(
      lanClient.effectivePriority,
      SyncPriority.initiatorWins,
      reason: 'server must echo the accepted direction',
    );
    expect(lanClient.forceSettingsExchange, isTrue);

    await lanClient.exchange(
      host: '127.0.0.1',
      port: lanServer.port!,
      pin: lanServer.pin!,
    );
    expect(lanClient.phase, LanSyncPhase.done);
    await serverDone.future.timeout(const Duration(seconds: 20));

    expect(clientRestored, isTrue);
    expect(serverRestored, isTrue);
    final serverAssistant = await server.assistant('a1');
    final initiatorAssistant = await initiator.assistant('a1');
    expect(serverAssistant?.name, 'Initiator Assistant');
    expect(initiatorAssistant?.name, 'Initiator Assistant');
    expect(initiatorAssistant?.name, serverAssistant?.name);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('e2e: initiator-only chat delta + serverWins converges both peers to '
      'the server settings (review round 2 scenario 2)', () async {
    await _seedChats(initiator, server, initiatorHasExtra: true);
    await initiator.repo.putAssistants([
      Assistant(id: 'a1', name: 'Initiator Assistant'),
    ]);
    await server.repo.putAssistants([
      Assistant(id: 'a1', name: 'Server Assistant'),
    ]);

    final lanServer = LanSyncServer(
      chatService: server.chatService,
      dataSync: server.dataSync,
    );
    await lanServer.start(preferredPort: 0);
    addTearDown(lanServer.stop);

    final lanClient = LanSyncClient(
      chatService: initiator.chatService,
      dataSync: initiator.dataSync,
    );
    addTearDown(lanClient.close);

    final serverDone = Completer<void>();
    var serverRestored = false;
    lanServer.onZipReceived = (zip) async {
      try {
        await _restoreZip(
          server,
          zip,
          lanServer.initiatorPriority,
          isInitiator: false,
        );
      } catch (e) {
        if (!serverDone.isCompleted) serverDone.completeError(e);
        return;
      }
      serverRestored = true;
      debugPrint(
        '[e2e] scenario2 post-restore server assistants: '
        '${(await server.repo.getAllAssistants()).map((a) => a.name).toList()}',
      );
      if (!serverDone.isCompleted) serverDone.complete();
    };
    var clientRestored = false;
    lanClient.onZipReceived = (zip) async {
      await _restoreZip(
        initiator,
        zip,
        lanClient.effectivePriority,
        isInitiator: true,
      );
      clientRestored = true;
    };

    await lanClient.negotiate(
      host: '127.0.0.1',
      port: lanServer.port!,
      pin: lanServer.pin!,
      syncPriority: SyncPriority.serverWins,
    );
    expect(lanClient.effectivePriority, SyncPriority.serverWins);

    // The initiator has its own chat delta, so the settings must ride in
    // the regular delta zip — forceSettingsExchange must NOT suppress it.
    expect(lanClient.forceSettingsExchange, isFalse);
    await lanClient.exchange(
      host: '127.0.0.1',
      port: lanServer.port!,
      pin: lanServer.pin!,
    );
    expect(lanClient.phase, LanSyncPhase.done);
    await serverDone.future.timeout(const Duration(seconds: 20));

    expect(clientRestored, isTrue);
    expect(serverRestored, isTrue);
    final serverAssistant = await server.assistant('a1');
    final initiatorAssistant = await initiator.assistant('a1');
    expect(serverAssistant?.name, 'Server Assistant');
    expect(initiatorAssistant?.name, 'Server Assistant');
    expect(initiatorAssistant?.name, serverAssistant?.name);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('e2e: metadata-only row conflict + initiatorWins converges both peers '
      'to the initiator metadata (review round 3 scenario 3)', () async {
    await _seedMetadataConflictChats(
      initiator,
      server,
      initiatorTitle: 'Initiator Chat',
      serverTitle: 'Server Chat',
    );
    expect(initiator.repo.getMessageCountSync('c1'), 2);
    expect(server.repo.getMessageCountSync('c1'), 2);

    final lanServer = LanSyncServer(
      chatService: server.chatService,
      dataSync: server.dataSync,
    );
    await lanServer.start(preferredPort: 0);
    addTearDown(lanServer.stop);

    final lanClient = LanSyncClient(
      chatService: initiator.chatService,
      dataSync: initiator.dataSync,
    );
    addTearDown(lanClient.close);

    final serverDone = Completer<void>();
    var serverRestored = false;
    lanServer.onZipReceived = (zip) async {
      try {
        await _restoreZip(
          server,
          zip,
          lanServer.initiatorPriority,
          isInitiator: false,
        );
      } catch (e) {
        if (!serverDone.isCompleted) serverDone.completeError(e);
        return;
      }
      serverRestored = true;
      debugPrint(
        '[e2e] scenario3 post-restore server conversation: '
        '${server.repo.getConversationSync('c1')?.title}',
      );
      if (!serverDone.isCompleted) serverDone.complete();
    };
    var clientRestored = false;
    lanClient.onZipReceived = (zip) async {
      await _restoreZip(
        initiator,
        zip,
        lanClient.effectivePriority,
        isInitiator: true,
      );
      clientRestored = true;
    };

    await lanClient.negotiate(
      host: '127.0.0.1',
      port: lanServer.port!,
      pin: lanServer.pin!,
      syncPriority: SyncPriority.initiatorWins,
    );
    expect(lanClient.effectivePriority, SyncPriority.initiatorWins);
    expect(lanClient.forceSettingsExchange, isTrue);

    await lanClient.exchange(
      host: '127.0.0.1',
      port: lanServer.port!,
      pin: lanServer.pin!,
    );
    expect(lanClient.phase, LanSyncPhase.done);
    await serverDone.future.timeout(const Duration(seconds: 20));

    expect(clientRestored, isTrue);
    expect(serverRestored, isTrue);
    final iConv = initiator.repo.getConversationSync('c1');
    final sConv = server.repo.getConversationSync('c1');
    expect(iConv?.title, 'Initiator Chat');
    expect(sConv?.title, 'Initiator Chat');
    expect(iConv?.isPinned, isTrue);
    expect(sConv?.isPinned, isTrue);
    expect(iConv?.summary, 'initiator summary');
    expect(sConv?.summary, 'initiator summary');
    for (final device in [initiator, server]) {
      expect(device.repo.getMessageCountSync('c1'), 2);
      expect(device.repo.getMessageIdsSync('c1'), ['m1', 'm2']);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('e2e: metadata-only row conflict + serverWins converges both peers to '
      'the server metadata (review round 3 scenario 4)', () async {
    await _seedMetadataConflictChats(
      initiator,
      server,
      initiatorTitle: 'Initiator Chat',
      serverTitle: 'Server Chat',
    );
    expect(initiator.repo.getMessageCountSync('c1'), 2);
    expect(server.repo.getMessageCountSync('c1'), 2);

    final lanServer = LanSyncServer(
      chatService: server.chatService,
      dataSync: server.dataSync,
    );
    await lanServer.start(preferredPort: 0);
    addTearDown(lanServer.stop);

    final lanClient = LanSyncClient(
      chatService: initiator.chatService,
      dataSync: initiator.dataSync,
    );
    addTearDown(lanClient.close);

    final serverDone = Completer<void>();
    var serverRestored = false;
    lanServer.onZipReceived = (zip) async {
      try {
        await _restoreZip(
          server,
          zip,
          lanServer.initiatorPriority,
          isInitiator: false,
        );
      } catch (e) {
        if (!serverDone.isCompleted) serverDone.completeError(e);
        return;
      }
      serverRestored = true;
      debugPrint(
        '[e2e] scenario4 post-restore server conversation: '
        '${server.repo.getConversationSync('c1')?.title}',
      );
      if (!serverDone.isCompleted) serverDone.complete();
    };
    var clientRestored = false;
    lanClient.onZipReceived = (zip) async {
      await _restoreZip(
        initiator,
        zip,
        lanClient.effectivePriority,
        isInitiator: true,
      );
      clientRestored = true;
    };

    await lanClient.negotiate(
      host: '127.0.0.1',
      port: lanServer.port!,
      pin: lanServer.pin!,
      syncPriority: SyncPriority.serverWins,
    );
    expect(lanClient.effectivePriority, SyncPriority.serverWins);
    expect(lanClient.forceSettingsExchange, isTrue);

    await lanClient.exchange(
      host: '127.0.0.1',
      port: lanServer.port!,
      pin: lanServer.pin!,
    );
    expect(lanClient.phase, LanSyncPhase.done);
    await serverDone.future.timeout(const Duration(seconds: 20));

    expect(clientRestored, isTrue);
    expect(serverRestored, isTrue);
    final iConv = initiator.repo.getConversationSync('c1');
    final sConv = server.repo.getConversationSync('c1');
    expect(iConv?.title, 'Server Chat');
    expect(sConv?.title, 'Server Chat');
    expect(iConv?.isPinned, isFalse);
    expect(sConv?.isPinned, isFalse);
    expect(iConv?.summary, isNull);
    expect(sConv?.summary, isNull);
    for (final device in [initiator, server]) {
      expect(device.repo.getMessageCountSync('c1'), 2);
      expect(device.repo.getMessageIdsSync('c1'), ['m1', 'm2']);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
