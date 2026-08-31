import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/sync/lan_sync_client.dart';
import 'package:Cuplivo/core/services/sync/lan_sync_logic.dart';
import 'package:Cuplivo/core/services/sync/lan_sync_models.dart';
import 'package:Cuplivo/core/services/sync/lan_sync_server.dart';
import 'package:Cuplivo/core/services/sync/windows_firewall.dart';

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

/// Minimal ChatService fake: only the index-building surface is real,
/// backed by an in-memory Drift repo.
class _FakeChatService extends ChatService {
  _FakeChatService(this._repo);

  final ChatDatabaseRepository _repo;
  final List<Conversation> _conversations = [];

  @override
  ChatDatabaseRepository get repo => _repo;

  /// Export paths (`_exportChatsToFile`, `_exportSettingsJson`) self-init
  /// when uninitialized — that would open a real SQLite file under the fake
  /// app-data dir and leave it locked for the teardown delete.
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
}

void main() {
  var businessPrefs = BusinessPreferences.memoryForTests();
  TestWidgetsFlutterBinding.ensureInitialized();

  group('lanSyncFindProxy', () {
    test('always returns DIRECT regardless of scheme or host', () {
      expect(
        lanSyncFindProxy(Uri.parse('http://192.168.1.100:9527/sync/plan')),
        'DIRECT',
      );
      expect(lanSyncFindProxy(Uri.parse('https://example.com')), 'DIRECT');
    });
  });

  group('filterLanIps', () {
    test('keeps non-loopback, drops loopback, dedupes, preserves order', () {
      expect(
        filterLanIps(['192.168.1.5', '127.0.0.1', '192.168.1.5', '10.0.0.2']),
        ['192.168.1.5', '10.0.0.2'],
      );
    });

    test('returns empty for all-loopback input', () {
      expect(filterLanIps(['127.0.0.1', '127.0.0.2']), isEmpty);
    });

    test('returns empty for empty input', () {
      expect(filterLanIps([]), isEmpty);
    });
  });

  group('WindowsFirewall helpers', () {
    test('rule name embeds the port without spaces or parentheses', () {
      expect(WindowsFirewall.ruleName(9527), 'Cuplivo-LanSync-TCP-9527');
      expect(WindowsFirewall.ruleName(12345), 'Cuplivo-LanSync-TCP-12345');
    });

    test('add-rule args are port-scoped', () {
      expect(WindowsFirewall.addRuleArgs(9527), [
        'advfirewall',
        'firewall',
        'add',
        'rule',
        'name=Cuplivo-LanSync-TCP-9527',
        'dir=in',
        'action=allow',
        'protocol=TCP',
        'localport=9527',
      ]);
    });

    test('show-rule args reference the same name', () {
      expect(WindowsFirewall.showRuleArgs(9527), [
        'advfirewall',
        'firewall',
        'show',
        'rule',
        'name=Cuplivo-LanSync-TCP-9527',
      ]);
    });

    test('delete-rule args reference the same name', () {
      expect(WindowsFirewall.deleteRuleArgs(9527), [
        'advfirewall',
        'firewall',
        'delete',
        'rule',
        'name=Cuplivo-LanSync-TCP-9527',
      ]);
    });

    test('elevated command re-invokes netsh via Start-Process -Verb RunAs', () {
      final cmd = WindowsFirewall.elevateAddRuleCommand(9527);
      expect(cmd, contains('Start-Process -Verb RunAs'));
      expect(cmd, contains("'name=Cuplivo-LanSync-TCP-9527'"));
      expect(cmd, contains("'localport=9527'"));
    });
  });

  group('LanSyncClient', () {
    late Directory tempDir;
    late ChatDatabaseRepository repo;
    late _FakeChatService chatService;
    late DataSync dataSync;

    /// Plan with a null `since` — exchange then never touches DataSync.
    late SyncPlan emptyPlan;

    setUp(() async {
      businessPrefs = BusinessPreferences.memoryForTests();
      // getMessageIdsSync reads a separate raw-sqlite sync connection, which
      // only exists for file-based repos after ensureReady().
      tempDir = await Directory.systemTemp.createTemp('cuplivo_lan_sync_test');
      // The SyncIndex now always carries the file manifest, whose builder
      // resolves app directories through the path provider.
      final prevProvider = PathProviderPlatform.instance;
      final support = Directory('${tempDir.path}/support');
      await support.create(recursive: true);
      PathProviderPlatform.instance = _FakePathProviderPlatform(support.path);
      addTearDown(() => PathProviderPlatform.instance = prevProvider);
      final dbFile = File('${tempDir.path}${Platform.pathSeparator}test.db');
      repo = ChatDatabaseRepository.open(file: dbFile);
      await repo.ensureReady();
      chatService = _FakeChatService(repo);
      dataSync = DataSync(preferences: businessPrefs, chatService: chatService);
      emptyPlan = SyncPlan(
        conversations: const [],
        missingAssistantIds: const [],
        remoteMissingAssistantIds: const [],
        since: null,
      );
    });

    tearDown(() async {
      await repo.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    http.Client clientWith({
      required http.Response Function() planResponse,
      required http.Response Function() exchangeResponse,
    }) {
      return MockClient((request) async {
        if (request.url.path == '/sync/plan') return planResponse();
        if (request.url.path == '/sync/exchange') return exchangeResponse();
        return http.Response('Not found', 404);
      });
    }

    test('negotiate sends index with PIN header and parses the plan', () async {
      final assistant = Assistant(id: 'a1', name: 'Alpha');
      await repo.putAssistants([assistant]);
      final conversation = Conversation(id: 'c1', title: 'Chat 1');
      await repo.putConversation(conversation);
      await repo.putMessage(
        ChatMessage(
          id: 'm1',
          role: 'user',
          content: 'hello',
          conversationId: 'c1',
          timestamp: DateTime(2025, 1, 1),
        ),
      );
      chatService._conversations.add(conversation);

      late http.Request captured;
      final lanClient = LanSyncClient(
        chatService: chatService,
        dataSync: dataSync,
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(emptyPlan.toJsonString(), 200);
        }),
      );

      final plan = await lanClient.negotiate(
        host: '192.168.1.100',
        port: 9527,
        pin: '1234',
      );

      expect(captured.url.toString(), 'http://192.168.1.100:9527/sync/plan');
      expect(captured.headers['X-Sync-Pin'], '1234');
      expect(captured.headers['Content-Type'], startsWith('application/json'));
      final sent = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(sent['conversations'], contains('c1'));
      expect(sent['conversations']['c1'], contains('m1'));
      expect(sent['assistantIds'], contains('a1'));
      expect(plan, same(lanClient.plan));
      expect(lanClient.phase, LanSyncPhase.planReceived);
    });

    test('negotiate throws on 401 (invalid PIN)', () async {
      final lanClient = LanSyncClient(
        chatService: chatService,
        dataSync: dataSync,
        httpClient: clientWith(
          planResponse: () => http.Response('Invalid PIN', 401),
          exchangeResponse: () => http.Response('unused', 500),
        ),
      );
      await expectLater(
        lanClient.negotiate(host: '192.168.1.100', port: 9527, pin: '0000'),
        throwsA(predicate((e) => '$e'.contains('Invalid PIN'))),
      );
      expect(lanClient.busy, isFalse);
    });

    test('negotiate throws on non-200 response', () async {
      final lanClient = LanSyncClient(
        chatService: chatService,
        dataSync: dataSync,
        httpClient: clientWith(
          planResponse: () => http.Response('boom', 500),
          exchangeResponse: () => http.Response('unused', 500),
        ),
      );
      await expectLater(
        lanClient.negotiate(host: '192.168.1.100', port: 9527, pin: '1234'),
        throwsA(predicate((e) => '$e'.contains('Plan request failed'))),
      );
    });

    test('exchange on failure resets phase and stays retryable', () async {
      final lanClient = LanSyncClient(
        chatService: chatService,
        dataSync: dataSync,
        httpClient: clientWith(
          planResponse: () => http.Response(emptyPlan.toJsonString(), 200),
          exchangeResponse: () => http.Response('boom', 500),
        ),
      );
      await lanClient.negotiate(host: '192.168.1.100', port: 9527, pin: '1234');
      await expectLater(
        lanClient.exchange(host: '192.168.1.100', port: 9527, pin: '1234'),
        throwsA(predicate((e) => '$e'.contains('Exchange failed'))),
      );
      expect(lanClient.phase, LanSyncPhase.planReceived);
      expect(lanClient.busy, isFalse);
    });

    test(
      'exchange keeps phase done when the restore callback throws',
      () async {
        // The section's _restoreAndRestart catches restore failures itself,
        // but if the callback still throws, the phase must stay `done` (NOT
        // reset to planReceived) so the widget's `_exchange` returns false
        // and the caller does not close twice (issue #182 double-pop guard).
        final zipBytes = utf8.encode('PK fake zip content');
        final lanClient = LanSyncClient(
          chatService: chatService,
          dataSync: dataSync,
          httpClient: clientWith(
            planResponse: () => http.Response(emptyPlan.toJsonString(), 200),
            exchangeResponse: () => http.Response.bytes(
              zipBytes,
              200,
              headers: {'content-type': 'application/zip'},
            ),
          ),
        );
        lanClient.onZipReceived = (zipFile) async {
          throw Exception('restore failed');
        };

        await lanClient.negotiate(
          host: '192.168.1.100',
          port: 9527,
          pin: '1234',
        );
        await expectLater(
          lanClient.exchange(host: '192.168.1.100', port: 9527, pin: '1234'),
          throwsA(predicate((e) => '$e'.contains('restore failed'))),
        );
        expect(lanClient.phase, LanSyncPhase.done);
        expect(lanClient.busy, isFalse);
      },
    );

    test(
      'exchange with empty response enters noData and skips restore',
      () async {
        var zipCallbackCalled = false;
        final lanClient = LanSyncClient(
          chatService: chatService,
          dataSync: dataSync,
          httpClient: clientWith(
            planResponse: () => http.Response(emptyPlan.toJsonString(), 200),
            exchangeResponse: () => http.Response(
              '{"empty":true}',
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
        lanClient.onZipReceived = (zipFile) async {
          zipCallbackCalled = true;
        };

        await lanClient.negotiate(
          host: '192.168.1.100',
          port: 9527,
          pin: '1234',
        );
        await lanClient.exchange(
          host: '192.168.1.100',
          port: 9527,
          pin: '1234',
        );

        expect(lanClient.phase, LanSyncPhase.noData);
        expect(zipCallbackCalled, isFalse);
      },
    );

    test('exchange with zip response saves the file and enters done', () async {
      final zipBytes = utf8.encode('PK fake zip content');
      File? receivedFile;
      final lanClient = LanSyncClient(
        chatService: chatService,
        dataSync: dataSync,
        httpClient: clientWith(
          planResponse: () => http.Response(emptyPlan.toJsonString(), 200),
          exchangeResponse: () => http.Response.bytes(
            zipBytes,
            200,
            headers: {'content-type': 'application/zip'},
          ),
        ),
      );
      lanClient.onZipReceived = (zipFile) async {
        receivedFile = zipFile;
      };

      await lanClient.negotiate(host: '192.168.1.100', port: 9527, pin: '1234');
      await lanClient.exchange(host: '192.168.1.100', port: 9527, pin: '1234');

      expect(lanClient.phase, LanSyncPhase.done);
      expect(receivedFile, isNotNull);
      expect(await receivedFile!.exists(), isTrue);
      expect(await receivedFile!.readAsBytes(), zipBytes);
      await receivedFile!.delete();
    });

    test(
      'exchange zip includes settings.json so settings/assistants sync',
      () async {
        // Full DataSync export path needs prefs + path provider fakes.
        businessPrefs = BusinessPreferences.memoryForTests({});
        PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);

        final conversation = Conversation(id: 'c1', title: 'Chat 1');
        await repo.putConversation(conversation);
        await repo.putMessage(
          ChatMessage(
            id: 'm1',
            role: 'user',
            content: 'hello',
            conversationId: 'c1',
            timestamp: DateTime(2025, 1, 1),
          ),
        );
        chatService._conversations.add(conversation);

        final plan = SyncPlan(
          conversations: const [],
          missingAssistantIds: const [],
          remoteMissingAssistantIds: const [],
          since: DateTime(2025, 1, 1),
        );
        late http.Request captured;
        final lanClient = LanSyncClient(
          chatService: chatService,
          dataSync: dataSync,
          httpClient: MockClient((request) async {
            if (request.url.path == '/sync/plan') {
              return http.Response(plan.toJsonString(), 200);
            }
            captured = request;
            return http.Response(
              '{"empty":true}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );

        await lanClient.negotiate(
          host: '192.168.1.100',
          port: 9527,
          pin: '1234',
        );
        await lanClient.exchange(
          host: '192.168.1.100',
          port: 9527,
          pin: '1234',
        );

        expect(lanClient.phase, LanSyncPhase.noData);
        expect(captured, isNotNull);
        final contentType = captured.headers['content-type']!;
        expect(contentType, startsWith('multipart/form-data'));
        final boundary = contentType.split('boundary=').last;
        final parts = parseMultipartBytes(captured.bodyBytes, boundary);
        final zipBytes = parts['zip'];
        expect(zipBytes, isNotNull);

        final archive = ZipDecoder().decodeBytes(zipBytes!);
        try {
          expect(archive.findFile('settings.json'), isNotNull);
          expect(archive.findFile('chats_meta.json'), isNotNull);
        } finally {
          archive.clearSync();
        }
      },
    );

    test(
      'confirmed priority forces a settings-only exchange with no chat delta',
      () async {
        // Regression for issue #615 P1: identical message IDs + different
        // settings/system prompts produce no chat/file delta — a confirmed
        // non-auto direction must still exchange a settings/assistants-only
        // payload so the merge direction actually applies.
        businessPrefs = BusinessPreferences.memoryForTests({});
        PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);

        final conversation = Conversation(id: 'c1', title: 'Chat 1');
        await repo.putConversation(conversation);
        await repo.putMessage(
          ChatMessage(
            id: 'm1',
            role: 'user',
            content: 'hello',
            conversationId: 'c1',
            timestamp: DateTime(2025, 1, 1),
          ),
        );
        chatService._conversations.add(conversation);

        final plan = SyncPlan(
          conversations: const [],
          missingAssistantIds: const [],
          remoteMissingAssistantIds: const [],
          since: null,
          syncPriority: SyncPriority.initiatorWins,
        );
        late http.Request captured;
        final lanClient = LanSyncClient(
          chatService: chatService,
          dataSync: dataSync,
          httpClient: MockClient((request) async {
            if (request.url.path == '/sync/plan') {
              return http.Response(plan.toJsonString(), 200);
            }
            captured = request;
            return http.Response(
              '{"empty":true}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );

        await lanClient.negotiate(
          host: '192.168.1.100',
          port: 9527,
          pin: '1234',
          syncPriority: SyncPriority.initiatorWins,
        );
        expect(lanClient.effectivePriority, SyncPriority.initiatorWins);
        expect(lanClient.forceSettingsExchange, isTrue);

        await lanClient.exchange(
          host: '192.168.1.100',
          port: 9527,
          pin: '1234',
        );

        expect(lanClient.phase, LanSyncPhase.noData);
        expect(captured, isNotNull);
        final boundary = captured.headers['content-type']!
            .split('boundary=')
            .last;
        final parts = parseMultipartBytes(captured.bodyBytes, boundary);
        final zipBytes = parts['zip'];
        expect(zipBytes, isNotNull, reason: 'forced session must ship a zip');

        final archive = ZipDecoder().decodeBytes(zipBytes!);
        try {
          expect(archive.findFile('settings.json'), isNotNull);
          final meta = archive.findFile('chats_meta.json');
          if (meta != null) {
            final decoded =
                jsonDecode(utf8.decode(meta.readBytes()!))
                    as Map<String, dynamic>;
            expect(
              decoded['conversation_count'],
              0,
              reason: 'settings-only payload must not export chat data',
            );
          }
        } finally {
          archive.clearSync();
        }
      },
    );

    test('confirmed priority ships metadata-only conversation rows without '
        'their messages', () async {
      // Issue #615 category D regression: identical message-ID lists with a
      // differing conversation row must reach the merge — the forced payload
      // carries the row AND excludes its messages.
      businessPrefs = BusinessPreferences.memoryForTests({});
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);

      final conversation = Conversation(
        id: 'c1',
        title: 'Chat 1',
        isPinned: true,
      );
      await repo.putConversation(conversation);
      chatService._conversations.add(conversation);

      final plan = SyncPlan(
        conversations: const [
          SyncConvPlan(
            conversationId: 'c1',
            conversationTitle: 'Chat 1',
            state: SyncConvState.identical,
            initiatorIncrementCount: 0,
            serverIncrementCount: 0,
            metadataOnly: true,
          ),
        ],
        missingAssistantIds: const [],
        remoteMissingAssistantIds: const [],
        since: null,
        syncPriority: SyncPriority.initiatorWins,
      );
      late http.Request captured;
      final lanClient = LanSyncClient(
        chatService: chatService,
        dataSync: dataSync,
        httpClient: MockClient((request) async {
          if (request.url.path == '/sync/plan') {
            return http.Response(plan.toJsonString(), 200);
          }
          captured = request;
          return http.Response(
            '{"empty":true}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await lanClient.negotiate(
        host: '192.168.1.100',
        port: 9527,
        pin: '1234',
        syncPriority: SyncPriority.initiatorWins,
      );
      expect(lanClient.forceSettingsExchange, isTrue);
      await lanClient.exchange(host: '192.168.1.100', port: 9527, pin: '1234');

      final boundary = captured.headers['content-type']!
          .split('boundary=')
          .last;
      final parts = parseMultipartBytes(captured.bodyBytes, boundary);
      final archive = ZipDecoder().decodeBytes(parts['zip']!);
      try {
        final meta = archive.findFile('chats_meta.json');
        final decoded =
            jsonDecode(utf8.decode(meta!.readBytes()!)) as Map<String, dynamic>;
        expect(
          decoded['conversation_count'],
          1,
          reason: 'the metadata-only row must ride the forced payload',
        );
        expect(
          decoded['message_count'],
          0,
          reason: 'identical message lists must not duplicate messages',
        );
        final convsFile = archive.findFile('conversations.jsonl');
        final rows = (utf8.decode(convsFile!.readBytes()!)).trim().split('\n');
        expect(rows, hasLength(1));
        expect(rows.single, contains('"isPinned":true'));
        final msgsFile = archive.findFile('messages.jsonl');
        expect(msgsFile, isNotNull);
        expect(
          utf8.decode(msgsFile!.readBytes()!).trim(),
          isEmpty,
          reason: 'no message lines may ride a metadata-only row',
        );
      } finally {
        archive.clearSync();
      }
    });

    test('unconfirmed priority (old server echo null) falls back to auto and '
        'forces nothing', () async {
      final lanClient = LanSyncClient(
        chatService: chatService,
        dataSync: dataSync,
        httpClient: clientWith(
          planResponse: () => http.Response(emptyPlan.toJsonString(), 200),
          exchangeResponse: () => http.Response(
            '{"empty":true}',
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );

      await lanClient.negotiate(
        host: '192.168.1.100',
        port: 9527,
        pin: '1234',
        syncPriority: SyncPriority.serverWins,
      );
      expect(lanClient.chosenPriority, SyncPriority.serverWins);
      expect(
        lanClient.effectivePriority,
        isNull,
        reason: 'no echo → auto (mixed-version symmetry)',
      );
      expect(lanClient.forceSettingsExchange, isFalse);

      await lanClient.exchange(host: '192.168.1.100', port: 9527, pin: '1234');
      expect(lanClient.phase, LanSyncPhase.noData);
    });

    test('identical echo confirms the chosen priority', () async {
      final plan = SyncPlan(
        conversations: const [],
        missingAssistantIds: const [],
        remoteMissingAssistantIds: const [],
        since: null,
        syncPriority: SyncPriority.serverWins,
      );
      final lanClient = LanSyncClient(
        chatService: chatService,
        dataSync: dataSync,
        httpClient: clientWith(
          planResponse: () => http.Response(plan.toJsonString(), 200),
          exchangeResponse: () => http.Response('unused', 200),
        ),
      );

      await lanClient.negotiate(
        host: '192.168.1.100',
        port: 9527,
        pin: '1234',
        syncPriority: SyncPriority.serverWins,
      );
      expect(lanClient.effectivePriority, SyncPriority.serverWins);
    });

    test(
      'negotiate computes outbound file stats from the plan since',
      () async {
        // Install the fake path provider so countFilesForSince walks real
        // temp dirs; restore the previous instance afterwards.
        final prevProvider = PathProviderPlatform.instance;
        final support = Directory('${tempDir.path}/support');
        await support.create(recursive: true);
        PathProviderPlatform.instance = _FakePathProviderPlatform(support.path);
        addTearDown(() => PathProviderPlatform.instance = prevProvider);

        // One qualifying upload file (mtime after the plan's since).
        final uploadDir = Directory('${support.path}/upload');
        await uploadDir.create(recursive: true);
        final f = File('${uploadDir.path}/a.bin');
        await f.writeAsBytes(List<int>.filled(16, 7));
        await f.setLastModified(DateTime(2026, 1, 2));

        final planWithSince = SyncPlan(
          conversations: const [],
          missingAssistantIds: const [],
          remoteMissingAssistantIds: const [],
          since: DateTime(2026, 1, 1),
          serverFileCount: 3,
          serverFileSizeBytes: 999,
        );

        final lanClient = LanSyncClient(
          chatService: chatService,
          dataSync: dataSync,
          httpClient: MockClient(
            (request) async => http.Response(planWithSince.toJsonString(), 200),
          ),
        );

        final plan = await lanClient.negotiate(
          host: '192.168.1.100',
          port: 9527,
          pin: '1234',
        );

        // Peer's inbound payload comes from the plan...
        expect(plan.serverFileCount, 3);
        expect(plan.serverFileSizeBytes, 999);
        // ...our own outbound payload is computed locally (1 file, 16 bytes).
        expect(lanClient.outboundFileCount, 1);
        expect(lanClient.outboundFileSizeBytes, 16);
      },
    );

    test(
      'modern peer: exchange packs exactly the file delta plus sync_manifest.json',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({});
        // setUp already installed the fake path provider rooted at
        // tempDir/support — drop files under its sync trees.
        final support = Directory('${tempDir.path}/support');
        final uploadDir = Directory('${support.path}/upload');
        await uploadDir.create(recursive: true);
        final a = File('${uploadDir.path}/a.bin');
        await a.writeAsBytes(List<int>.filled(16, 7));
        await a.setLastModified(DateTime(2026, 1, 2));
        final wsDir = Directory('${support.path}/workspaces');
        await wsDir.create(recursive: true);
        final w = File('${wsDir.path}/w.txt');
        await w.writeAsString('data');
        await w.setLastModified(DateTime(2026, 1, 3));
        final wMtimeMs = w.statSync().modified.millisecondsSinceEpoch;

        final peerManifest = <String, FileManifestEntry>{
          // a.bin exists on the peer but OLDER → we send ours.
          'upload/a.bin': FileManifestEntry(
            size: 16,
            mtimeMs: DateTime(2026, 1, 1).millisecondsSinceEpoch,
          ),
          // peer-only file we lack → never in our outbound delta.
          'upload/peer-only.bin': FileManifestEntry(
            size: 5,
            mtimeMs: DateTime(2026, 1, 1).millisecondsSinceEpoch,
          ),
        };
        final plan = SyncPlan(
          conversations: const [],
          missingAssistantIds: const [],
          remoteMissingAssistantIds: const [],
          since: null,
          serverFileManifest: peerManifest,
        );
        late http.Request captured;
        final lanClient = LanSyncClient(
          chatService: chatService,
          dataSync: dataSync,
          httpClient: MockClient((request) async {
            if (request.url.path == '/sync/plan') {
              return http.Response(plan.toJsonString(), 200);
            }
            captured = request;
            return http.Response(
              '{"empty":true}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );

        await lanClient.negotiate(
          host: '192.168.1.100',
          port: 9527,
          pin: '1234',
        );
        // File-only delta (all conversations identical, since null) still
        // drives the exchange.
        expect(lanClient.outboundFileCount, 2);
        expect(lanClient.phase, LanSyncPhase.planReceived);
        await lanClient.exchange(
          host: '192.168.1.100',
          port: 9527,
          pin: '1234',
        );

        expect(lanClient.phase, LanSyncPhase.noData);
        expect(captured, isNotNull);
        final contentType = captured.headers['content-type']!;
        final boundary = contentType.split('boundary=').last;
        final parts = parseMultipartBytes(captured.bodyBytes, boundary);
        final zipBytes = parts['zip'];
        expect(zipBytes, isNotNull);

        final archive = ZipDecoder().decodeBytes(zipBytes!);
        try {
          // Exactly the delta files are packed; the peer-only file is not.
          expect(archive.findFile('upload/a.bin'), isNotNull);
          expect(archive.findFile('workspaces/w.txt'), isNotNull);
          expect(archive.findFile('upload/peer-only.bin'), isNull);
          // ms-precision manifest rides inside the zip.
          final manifestEntry = archive.findFile('sync_manifest.json');
          expect(manifestEntry, isNotNull);
          final manifest =
              jsonDecode(utf8.decode(manifestEntry!.readBytes() ?? <int>[]))
                  as Map<String, dynamic>;
          expect(manifest, contains('upload/a.bin'));
          expect(manifest, contains('workspaces/w.txt'));
          expect((manifest['workspaces/w.txt'] as Map)['mtime'], wMtimeMs);
        } finally {
          archive.clearSync();
        }
      },
    );

    test(
      'per-conversation since exports only that conversation\u2019s increments',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({});
        final conversation = Conversation(id: 'c1', title: 'Chat 1');
        await repo.putConversation(conversation);
        // Pre-fork history (before this conversation's fork point) and the
        // post-fork increment.
        await repo.putMessage(
          ChatMessage(
            id: 'm_old',
            role: 'user',
            content: 'history',
            conversationId: 'c1',
            timestamp: DateTime(2025, 1, 1),
          ),
        );
        await repo.putMessage(
          ChatMessage(
            id: 'm_new',
            role: 'user',
            content: 'increment',
            conversationId: 'c1',
            timestamp: DateTime(2025, 1, 3),
          ),
        );
        chatService._conversations.add(conversation);

        // Modern server: the plan carries the per-conversation fork timestamp
        // (the fork message 'mf' has 2025-01-02), so the export window is this
        // conversation's own fork point — pre-fork m_old (2025-01-01) is NOT
        // re-sent even though it predates the global since too.
        final plan = SyncPlan(
          conversations: const [
            SyncConvPlan(
              conversationId: 'c1',
              state: SyncConvState.initiatorOnly,
              forkPointMessageId: 'mf',
              initiatorIncrementCount: 1,
              serverIncrementCount: 0,
              since: null,
            ),
          ],
          missingAssistantIds: const [],
          remoteMissingAssistantIds: const [],
          since: DateTime(2025, 1, 2),
          serverFileManifest: const {},
        );
        final resolvedPlan = SyncPlan(
          conversations: [
            SyncConvPlan(
              conversationId: 'c1',
              state: SyncConvState.initiatorOnly,
              forkPointMessageId: 'mf',
              initiatorIncrementCount: 1,
              serverIncrementCount: 0,
              since: DateTime(2025, 1, 2),
            ),
          ],
          missingAssistantIds: const [],
          remoteMissingAssistantIds: const [],
          since: DateTime(2025, 1, 2),
          serverFileManifest: const {},
        );
        expect(plan.since, DateTime(2025, 1, 2));
        expect(resolvedPlan.conversations.single.since, DateTime(2025, 1, 2));

        late http.Request captured;
        final lanClient = LanSyncClient(
          chatService: chatService,
          dataSync: dataSync,
          httpClient: MockClient((request) async {
            if (request.url.path == '/sync/plan') {
              return http.Response(resolvedPlan.toJsonString(), 200);
            }
            captured = request;
            return http.Response(
              '{"empty":true}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );

        await lanClient.negotiate(
          host: '192.168.1.100',
          port: 9527,
          pin: '1234',
        );
        await lanClient.exchange(
          host: '192.168.1.100',
          port: 9527,
          pin: '1234',
        );

        final contentType = captured.headers['content-type']!;
        final boundary = contentType.split('boundary=').last;
        final parts = parseMultipartBytes(captured.bodyBytes, boundary);
        final archive = ZipDecoder().decodeBytes(parts['zip']!);
        try {
          final chatsMetaEntry = archive.findFile('chats_meta.json');
          expect(chatsMetaEntry, isNotNull);
          final messages = _readJsonlMessages(archive, 'messages.jsonl');
          // Only the post-fork increment is exported; pre-fork m_old is not.
          expect(messages, hasLength(1));
          expect(messages.single['id'], 'm_new');
        } finally {
          archive.clearSync();
        }
      },
    );

    test('one-sided conversations export their whole transcript', () async {
      businessPrefs = BusinessPreferences.memoryForTests({});
      final conversation = Conversation(id: 'c1', title: 'Chat 1');
      await repo.putConversation(conversation);
      await repo.putMessage(
        ChatMessage(
          id: 'm1',
          role: 'user',
          content: 'only',
          conversationId: 'c1',
          timestamp: DateTime(2020, 1, 1),
        ),
      );
      chatService._conversations.add(conversation);

      final plan = SyncPlan(
        conversations: const [
          SyncConvPlan(
            conversationId: 'c1',
            state: SyncConvState.initiatorOnly,
            forkPointMessageId: null,
            initiatorIncrementCount: 1,
            serverIncrementCount: 0,
            since: null,
          ),
        ],
        missingAssistantIds: const [],
        remoteMissingAssistantIds: const [],
        since: DateTime(2025, 1, 2),
        serverFileManifest: const {},
      );
      late http.Request captured;
      final lanClient = LanSyncClient(
        chatService: chatService,
        dataSync: dataSync,
        httpClient: MockClient((request) async {
          if (request.url.path == '/sync/plan') {
            return http.Response(plan.toJsonString(), 200);
          }
          captured = request;
          return http.Response(
            '{"empty":true}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await lanClient.negotiate(host: '192.168.1.100', port: 9527, pin: '1234');
      await lanClient.exchange(host: '192.168.1.100', port: 9527, pin: '1234');

      final contentType = captured.headers['content-type']!;
      final boundary = contentType.split('boundary=').last;
      final parts = parseMultipartBytes(captured.bodyBytes, boundary);
      final archive = ZipDecoder().decodeBytes(parts['zip']!);
      try {
        final chatsMetaEntry = archive.findFile('chats_meta.json');
        expect(chatsMetaEntry, isNotNull);
        // Null per-conversation since → the whole (ancient) transcript rides.
        final messages = _readJsonlMessages(archive, 'messages.jsonl');
        expect(messages, hasLength(1));
        expect(messages.single['id'], 'm1');
      } finally {
        archive.clearSync();
      }
    });

    test(
      'old peer: client falls back to the global since for the chat export',
      () async {
        businessPrefs = BusinessPreferences.memoryForTests({});
        final conversation = Conversation(
          id: 'c1',
          title: 'Chat 1',
          createdAt: DateTime(2025, 1, 1),
          updatedAt: DateTime(2025, 1, 3),
        );
        await repo.putConversation(conversation);
        await repo.putMessage(
          ChatMessage(
            id: 'm_old',
            role: 'user',
            content: 'history',
            conversationId: 'c1',
            timestamp: DateTime(2025, 1, 1),
          ),
        );
        await repo.putMessage(
          ChatMessage(
            id: 'm_new',
            role: 'user',
            content: 'increment',
            conversationId: 'c1',
            timestamp: DateTime(2025, 1, 3),
          ),
        );
        chatService._conversations.add(conversation);

        // Old server: no serverFileManifest, no per-conversation since. The
        // client must NOT fall into per-conversation mode (which would export
        // the whole transcript) — it keeps the global-since message filter.
        final plan = SyncPlan(
          conversations: const [
            SyncConvPlan(
              conversationId: 'c1',
              state: SyncConvState.initiatorOnly,
              forkPointMessageId: 'mf',
              initiatorIncrementCount: 1,
              serverIncrementCount: 0,
              since: null,
            ),
          ],
          missingAssistantIds: const [],
          remoteMissingAssistantIds: const [],
          since: DateTime(2025, 1, 2),
        );
        late http.Request captured;
        final lanClient = LanSyncClient(
          chatService: chatService,
          dataSync: dataSync,
          httpClient: MockClient((request) async {
            if (request.url.path == '/sync/plan') {
              return http.Response(plan.toJsonString(), 200);
            }
            captured = request;
            return http.Response(
              '{"empty":true}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );

        await lanClient.negotiate(
          host: '192.168.1.100',
          port: 9527,
          pin: '1234',
        );
        await lanClient.exchange(
          host: '192.168.1.100',
          port: 9527,
          pin: '1234',
        );

        final contentType = captured.headers['content-type']!;
        final boundary = contentType.split('boundary=').last;
        final parts = parseMultipartBytes(captured.bodyBytes, boundary);
        final archive = ZipDecoder().decodeBytes(parts['zip']!);
        try {
          final chatsMetaEntry = archive.findFile('chats_meta.json');
          expect(chatsMetaEntry, isNotNull);
          // Global-since window: only the post-since increment rides; the
          // pre-since history is not re-sent (a full transcript would include
          // m_old and indicate per-conversation mode leaked in).
          final messages = _readJsonlMessages(archive, 'messages.jsonl');
          expect(messages, hasLength(1));
          expect(messages.single['id'], 'm_new');
        } finally {
          archive.clearSync();
        }
      },
    );
  });
}

/// Decodes the JSONL messages table (backup v2 format) into a list of
/// message payload maps.
List<Map> _readJsonlMessages(Archive archive, String table) {
  final entry = archive.findFile(table);
  expect(entry, isNotNull);
  final output = <Map>[];
  for (final raw in utf8.decode(entry!.readBytes() ?? <int>[]).split('\n')) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) continue;
    final obj = jsonDecode(trimmed) as Map<String, dynamic>;
    final message = obj['message'];
    if (message != null) output.add(message as Map);
  }
  return output;
}
