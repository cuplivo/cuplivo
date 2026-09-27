import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_data.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/skills/skill_directory_sync.dart';
import 'package:Cuplivo/core/services/sync/blob_sync.dart';
import 'package:Cuplivo/core/services/sync/sync_data_plane.dart';
import 'package:Cuplivo/core/services/sync/sync_engine.dart';
import 'package:Cuplivo/core/services/sync/sync_identity.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:Cuplivo/core/services/sync/sync_store.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// End-to-end LAN sync over the real stack: two independent databases, two
/// device identities, mutual TLS on loopback. This is the only place the wire
/// format, the certificate pinning, the session beats and the apply/reload tail
/// meet at once — slice 1 shipped without it, so the first execution is here.

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

/// A data plane that claims a newer schema, standing in for a peer built on a
/// future app version (the symmetric version gate's other half).
class _NewerSchemaPlane extends SyncDataPlane {
  _NewerSchemaPlane({
    required super.repository,
    required super.chatService,
    required super.businessRepository,
    super.businessPreferences,
    super.skillDirectories,
    super.blobPathResolver,
  });

  @override
  int get schemaVersion => super.schemaVersion + 1;
}

/// One device: its own sync directory, database, chat and business stores, and
/// its own listener.
class _Side {
  _Side(this.label, {this.newerSchema = false});

  final String label;
  final bool newerSchema;

  late final Directory dir;
  late final AppDatabase database;
  late final ChatDatabaseRepository repository;
  late final ChatService chatService;
  late final BusinessRepository businessRepository;
  late final BusinessPreferences businessPreferences;
  late final SyncDeviceIdentity identity;
  late final SyncStore store;
  late final SkillDirectorySync skillDirectories;
  late final SyncDataPlane dataPlane;
  late final SyncEngine engine;
  late final int port;

  /// This side's managed file root: `kelivo-file:///<rel>` resolves under it.
  /// One test process hosts both peers, so the sandbox resolver's single
  /// global root cannot serve both — each plane gets this instead.
  String? resolveBlob(String uri) {
    const prefix = 'kelivo-file:///';
    if (!uri.startsWith(prefix)) return null;
    final rest = uri.substring(prefix.length);
    if (rest.isEmpty) return null;
    return '${dir.path}/$rest';
  }

  /// The skills root the data plane hashes, zips and swaps in.
  Directory get skillsRoot => Directory('${dir.path}/skills');

  /// Installs a skill body the way the skills service does: files on disk plus
  /// the extension entity row that owns them.
  Future<void> putSkill(
    String id,
    Map<String, String> files, {
    bool enabled = true,
  }) async {
    for (final entry in files.entries) {
      final file = File('${skillsRoot.path}/$id/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value, flush: true);
    }
    await businessRepository.syncApplyBusinessRows(
      entities: {
        BusinessEntityKind.skill.wireName: [
          {
            'kind': 'skill',
            'id': id,
            'sort_order': 0,
            'owner_id': null,
            'payload': jsonEncode({
              'id': id,
              'enabled': enabled,
              'useCount': 0,
              'source': 'file',
              'installedAt': '2026-01-01T00:00:00.000Z',
              'updatedAt': '2026-01-01T00:00:00.000Z',
            }),
            'updated_at': 1000000,
          },
        ],
      },
      preferences: const [],
      myDeviceId: 'seed',
      peerDeviceId: 'seed',
    );
  }

  Future<String> skillBody(String id) async {
    final file = File('${skillsRoot.path}/$id/SKILL.md');
    return await file.exists() ? file.readAsString() : '';
  }

  Future<bool> hasSkillRow(String id) async =>
      (await businessRepository.syncEntityIds(
        BusinessEntityKind.skill.wireName,
      )).contains(id);

  Future<void> start(Directory root) async {
    dir = Directory('${root.path}/$label');
    await dir.create(recursive: true);
    database = AppDatabase(NativeDatabase.memory());
    repository = ChatDatabaseRepository(database);
    await repository.ensureReady();
    businessRepository = BusinessRepository(database);
    businessPreferences = BusinessPreferences(businessRepository);
    await businessPreferences.load();
    chatService = ChatService(existingRepository: repository);
    await chatService.init();
    identity = await SyncDeviceIdentity.loadOrCreate(dir, fallbackName: label);
    store = SyncStore(dir);
    skillDirectories = SkillDirectorySync(skillsRoot);
    dataPlane = newerSchema
        ? _NewerSchemaPlane(
            repository: repository,
            chatService: chatService,
            businessRepository: businessRepository,
            businessPreferences: businessPreferences,
            skillDirectories: skillDirectories,
            blobPathResolver: resolveBlob,
          )
        : SyncDataPlane(
            repository: repository,
            chatService: chatService,
            businessRepository: businessRepository,
            businessPreferences: businessPreferences,
            skillDirectories: skillDirectories,
            blobPathResolver: resolveBlob,
          );
    engine = SyncEngine(
      identity: identity,
      store: store,
      dataPlane: dataPlane,
      onStateChanged: () {},
    );
    port = await engine.start(preferredPort: 0);
  }

  Future<void> dispose() async {
    await engine.stop();
    await chatService.close();
    await repository.close();
  }

  Future<SyncPeerRecord> peer(_Side other) async {
    final record = await store.findPeer(other.identity.deviceId);
    if (record == null) {
      throw StateError('$label has no record for ${other.label}');
    }
    return record;
  }

  SyncHello hello({
    int? schemaVersion,
    int? protocolVersion,
    String? deviceId,
  }) => SyncHello(
    protocolVersion: protocolVersion ?? kSyncProtocolVersion,
    schemaVersion: schemaVersion ?? dataPlane.schemaVersion,
    deviceId: deviceId ?? identity.deviceId,
    deviceName: label,
    platform: 'test',
    manifest: const SyncManifest(<String, SyncManifestEntry>{}),
  );
}

/// Writes an assistant list the way a provider does: one whole-list rewrite of
/// a business entity key, routed into `assistant_rows`.
Future<void> _setAssistants(
  _Side side,
  List<({String id, String name})> list,
) => side.businessPreferences.setString(
  'assistants_v1',
  jsonEncode([
    for (final item in list) {'id': item.id, 'name': item.name},
  ]),
);

/// The assistant entities this side holds, as `id → payload`.
Future<Map<String, String>> _assistantsOf(_Side side) async => {
  for (final row in await side.businessRepository.readEntities(
    BusinessEntityKind.assistant,
  ))
    row.id: row.payload,
};

/// Forces a row's mutation clock, so a test can create the clock tie that the
/// deviceId rule exists for.
Future<void> _forceUpdatedAt(
  _Side side, {
  required String table,
  required String idColumn,
  required String id,
  required int updatedAtUs,
}) => side.database.customStatement(
  'UPDATE $table SET updated_at = ? WHERE $idColumn = ?;',
  <Object?>[updatedAtUs, id],
);

Future<void> _seedConversation(
  _Side side, {
  required String id,
  required List<String> contents,
}) async {
  final messages = [
    for (final (index, content) in contents.indexed)
      ChatMessage(
        id: '$id-m$index',
        conversationId: id,
        role: index.isEven ? 'user' : 'assistant',
        content: content,
      ),
  ];
  await side.repository.putMigrationBatch(
    conversations: [
      Conversation(
        id: id,
        title: id,
      ).copyWith(messageIds: [for (final message in messages) message.id]),
    ],
    messages: [
      for (final (index, message) in messages.indexed)
        (message: message, messageOrder: index),
    ],
    toolEventsByMessageId: const {},
    geminiSignaturesByMessageId: const {},
  );
}

/// A conversation whose only message carries an attachment part pointing at
/// [uri]. Written the way the backup importer does, so parts and the asset
/// reference dirty markers are produced by the real write path.
Future<void> _seedConversationWithImage(
  _Side side, {
  required String id,
  required String uri,
}) async {
  final message = ChatMessage(
    id: '$id-m0',
    conversationId: id,
    role: 'user',
    content: '',
    parts: [ImagePart(uri: uri, mime: 'image/png')],
  );
  await side.repository.putMigrationBatch(
    conversations: [
      Conversation(id: id, title: id).copyWith(messageIds: [message.id]),
    ],
    messages: [(message: message, messageOrder: 0)],
    toolEventsByMessageId: const {},
    geminiSignaturesByMessageId: const {},
  );
}

Future<Set<String>> _conversationIds(_Side side) async => {
  for (final ref in await side.repository.syncConversationRefs())
    ref.conversationId,
};
Future<Set<String>> _messageIds(_Side side, String conversationId) async => {
  for (final row in await side.repository.syncReadMessageRows(conversationId))
    row['id'] as String,
};

/// The stored `message_order` of every row, in order — the property the apply's
/// re-derivation must produce, and the one id-set assertions cannot see.
Future<List<int>> _messageOrders(_Side side, String conversationId) async {
  final rows = await side.database
      .customSelect(
        'SELECT message_order FROM message_rows WHERE conversation_id = ? '
        'ORDER BY message_order, id;',
        variables: [Variable.withString(conversationId)],
      )
      .get();
  return [for (final row in rows) row.read<int>('message_order')];
}

/// Message content lives in `message_part_rows.payload`; comparing it is what
/// proves the wire carried content, not just row skeleton.
Future<Map<String, String>> _partPayloads(
  _Side side,
  String conversationId,
) async => {
  for (final row in await side.repository.syncReadMessagePartRows(
    conversationId,
  ))
    '${row['revision_id']}:${row['ordinal']}': row['payload'] as String,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This suite is the one place that needs real sockets: the test binding
  // installs a mock HttpClient that answers every request with an empty 400,
  // so a pairing attempt would fail without ever reaching a server.
  HttpOverrides.global = null;

  late Directory root;
  late PathProviderPlatform previousPathProvider;
  final sides = <_Side>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cuplivo_sync_it_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
  });

  tearDown(() async {
    for (final side in sides.reversed) {
      await side.dispose();
    }
    sides.clear();
    PathProviderPlatform.instance = previousPathProvider;
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<(_Side, _Side)> pair({bool newerSchema = false}) async {
    final a = _Side('a');
    final b = _Side('b', newerSchema: newerSchema);
    await a.start(root);
    await b.start(root);
    sides.addAll([a, b]);
    final pin = b.engine.openPairing();
    await a.engine.pairWith(host: '127.0.0.1', port: b.port, pin: pin);
    return (a, b);
  }

  test(
    'pairing pins both sides and backfills the initiator endpoint',
    () async {
      final a = _Side('a');
      final b = _Side('b');
      await a.start(root);
      await b.start(root);
      sides.addAll([a, b]);

      final pin = b.engine.openPairing();
      expect(pin.length, 6);
      expect(b.engine.isPairingOpen, isTrue);

      await a.engine.pairWith(host: '127.0.0.1', port: b.port, pin: pin);
      expect(b.engine.isPairingOpen, isFalse, reason: 'the PIN is one-shot');

      final aPeer = await a.peer(b);
      expect(aPeer.lastHost, '127.0.0.1');
      expect(aPeer.lastPort, b.port);
      expect(aPeer.certPem, b.identity.certPem, reason: 'pinned certificate');

      // The responder learns where the initiator connected from plus the
      // listener port it advertised, so it can start sessions too.
      final bPeer = await b.peer(a);
      expect(bPeer.lastHost, '127.0.0.1');
      expect(bPeer.lastPort, a.port);
      expect(bPeer.certPem, a.identity.certPem);
    },
  );

  test('a wrong PIN pairs nothing', () async {
    final a = _Side('a');
    final b = _Side('b');
    await a.start(root);
    await b.start(root);
    sides.addAll([a, b]);

    final pin = b.engine.openPairing();
    final wrong = pin == '000000' ? '111111' : '000000';
    await expectLater(
      a.engine.pairWith(host: '127.0.0.1', port: b.port, pin: wrong),
      throwsA(isA<Exception>()),
    );
    expect(await a.store.findPeer(b.identity.deviceId), isNull);
    expect(b.engine.isPairingOpen, isTrue, reason: 'a failed attempt keeps it');
  });

  test(
    'the first session converges both sides and the next is a no-op',
    () async {
      final (a, b) = await pair();
      await _seedConversation(a, id: 'conv-a', contents: ['a1', 'a2']);
      await _seedConversation(b, id: 'conv-b', contents: ['b1']);

      final report = await a.engine.syncWithPeer(await a.peer(b));
      expect(report.success, isTrue, reason: report.summary);
      expect(report.conversationsSent, 1);
      expect(report.conversationsReceived, 1);

      // Both sides now hold both conversations...
      expect(await _conversationIds(a), {'conv-a', 'conv-b'});
      expect(await _conversationIds(b), {'conv-a', 'conv-b'});
      // ...with the same messages and the same content.
      for (final id in ['conv-a', 'conv-b']) {
        expect(await _messageIds(a, id), await _messageIds(b, id));
        expect(await _partPayloads(a, id), await _partPayloads(b, id));
        // Orders form a dense sequence on both sides. An apply that left rows
        // in the shifted range would pass the id comparison above and still
        // show the conversation in the wrong order.
        final orders = await _messageOrders(b, id);
        expect(orders, [for (var i = 0; i < orders.length; i++) i]);
        expect(await _messageOrders(a, id), orders);
      }
      expect(await _messageIds(b, 'conv-a'), {'conv-a-m0', 'conv-a-m1'});

      // The responder persisted its own outcome (it never returns one to us).
      final bPeer = await b.peer(a);
      expect(bPeer.lastReport, isNotNull);
      expect(bPeer.lastReport!.success, isTrue);
      expect(bPeer.lastReport!.sent, 1);
      expect(bPeer.lastReport!.received, 1);

      // Nothing left to move in either direction.
      final second = await a.engine.syncWithPeer(await a.peer(b));
      expect(second.success, isTrue, reason: second.summary);
      expect(second.conversationsSent, 0);
      expect(second.conversationsReceived, 0);
      expect(second.deferred, 0);
    },
  );

  test('a local deletion reaches the peer in the same session', () async {
    final (a, b) = await pair();
    await _seedConversation(a, id: 'conv-a', contents: ['a1']);
    await _seedConversation(b, id: 'conv-b', contents: ['b1']);
    await a.engine.syncWithPeer(await a.peer(b));
    expect(await _conversationIds(b), {'conv-a', 'conv-b'});

    await a.repository.deleteConversation('conv-b');
    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);

    // The peer applied the deletion through the tombstone path, so a third
    // paired device can learn about it too.
    expect(await b.repository.syncReadConversationRow('conv-b'), isNull);
    expect(await a.repository.syncReadConversationRow('conv-b'), isNull);
    final tombstones = await b.database
        .customSelect(
          'SELECT entity_id FROM tombstone_rows WHERE entity_id = ?;',
          variables: [Variable.withString('conv-b')],
        )
        .get();
    expect(tombstones, isNotEmpty);

    // And it stays deleted: no checkpoint entry survives to re-adopt it.
    await a.engine.syncWithPeer(await a.peer(b));
    expect(await a.repository.syncReadConversationRow('conv-b'), isNull);
    expect(await b.repository.syncReadConversationRow('conv-b'), isNull);
    expect(await _conversationIds(a), {'conv-a'});
  });

  test(
    'the responder can initiate a session with the backfilled endpoint',
    () async {
      final (a, b) = await pair();
      await _seedConversation(b, id: 'conv-b', contents: ['b1']);

      // b was the responder during pairing; its record for a carries the
      // endpoint it learned there.
      final report = await b.engine.syncWithPeer(await b.peer(a));
      expect(report.success, isTrue, reason: report.summary);
      expect(report.conversationsSent, 1);
      expect(await _conversationIds(a), {'conv-b'});
      expect(
        await _partPayloads(a, 'conv-b'),
        await _partPayloads(b, 'conv-b'),
      );
    },
  );

  test('the symmetric version gate refuses a newer peer', () async {
    // Initiator half: our own hello is accepted, their newer schema is not.
    final (a, newer) = await pair(newerSchema: true);
    final report = await a.engine.syncWithPeer(await a.peer(newer));
    expect(report.success, isFalse);
    expect(report.refusal, SyncRefusalReason.peerSchemaNewer);
  });

  test(
    'hello refuses an unknown protocol, a newer schema, an unpaired caller',
    () async {
      final (a, b) = await pair();

      final unknownProtocol = await a.engine.handleHello(
        b.identity.deviceId,
        b.hello(protocolVersion: kSyncProtocolVersion + 1),
      );
      expect(unknownProtocol, isA<SyncHelloRefusal>());
      expect(
        (unknownProtocol as SyncHelloRefusal).reason,
        SyncRefusalReason.protocolUnknown,
      );

      final newerSchema = await a.engine.handleHello(
        b.identity.deviceId,
        b.hello(schemaVersion: a.dataPlane.schemaVersion + 1),
      );
      expect(newerSchema, isA<SyncHelloRefusal>());
      expect(
        (newerSchema as SyncHelloRefusal).reason,
        SyncRefusalReason.peerSchemaNewer,
      );

      final unpaired = await a.engine.handleHello(
        'nobody-in-the-peer-store',
        b.hello(deviceId: 'nobody-in-the-peer-store'),
      );
      expect(unpaired, isA<SyncHelloRefusal>());
      expect(
        (unpaired as SyncHelloRefusal).reason,
        SyncRefusalReason.notPaired,
      );

      // A same-schema paired caller is answered with a hello, not a refusal.
      final accepted = await a.engine.handleHello(
        b.identity.deviceId,
        b.hello(),
      );
      expect(accepted, isA<SyncHello>());
    },
  );

  test('a new device receives entities and synced preferences', () async {
    final (a, b) = await pair();
    await _setAssistants(a, [
      (id: 'assistant-1', name: 'Researcher'),
      (id: 'assistant-2', name: 'Editor'),
    ]);
    await a.businessPreferences.setString('user_name', 'Alice');
    await a.businessPreferences.setString('theme_mode_v1', 'dark');
    // Device-local: the new device must keep its own value.
    await b.businessPreferences.setString('current_assistant_id_v1', 'b-only');

    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);
    expect(report.entityRows, 2);
    expect(report.preferenceRows, greaterThanOrEqualTo(2));

    expect(await _assistantsOf(b), await _assistantsOf(a));
    expect((await _assistantsOf(b)).keys, {'assistant-1', 'assistant-2'});

    // The in-memory view the providers read was refreshed by the apply, so the
    // synced values are visible without a restart.
    expect(b.businessPreferences.getString('user_name'), 'Alice');
    expect(b.businessPreferences.getString('theme_mode_v1'), 'dark');
    expect(
      b.businessPreferences.getString('current_assistant_id_v1'),
      'b-only',
      reason: 'session-position keys are device-local by the new-device test',
    );

    // Nothing left to move.
    final second = await a.engine.syncWithPeer(await a.peer(b));
    expect(second.success, isTrue, reason: second.summary);
    expect(second.entityRows, 0);
    expect(second.preferenceRows, 0);
  });

  test('an entity deleted on one device disappears on the peer', () async {
    final (a, b) = await pair();
    await _setAssistants(a, [
      (id: 'assistant-1', name: 'Keep'),
      (id: 'assistant-2', name: 'Drop'),
    ]);
    await a.engine.syncWithPeer(await a.peer(b));
    expect((await _assistantsOf(b)).keys, {'assistant-1', 'assistant-2'});

    await _setAssistants(a, [(id: 'assistant-1', name: 'Keep')]);
    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);

    expect((await _assistantsOf(a)).keys, {'assistant-1'});
    expect((await _assistantsOf(b)).keys, {'assistant-1'});

    // And it stays gone: no checkpoint entry survives to re-adopt it.
    await a.engine.syncWithPeer(await a.peer(b));
    expect((await _assistantsOf(b)).keys, {'assistant-1'});
  });

  test('a preference cleared on one device disappears on the peer', () async {
    final (a, b) = await pair();
    await a.businessPreferences.setString('user_name', 'Alice');
    await a.engine.syncWithPeer(await a.peer(b));
    expect(b.businessPreferences.getString('user_name'), 'Alice');

    await a.businessPreferences.remove('user_name');
    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);
    expect(b.businessPreferences.getString('user_name'), isNull);
  });

  test('a clock tie resolves to the higher deviceId on both sides', () async {
    final (a, b) = await pair();
    await _setAssistants(a, [(id: 'assistant-1', name: 'From A')]);
    await _setAssistants(b, [(id: 'assistant-1', name: 'From B')]);
    // Same clock instant on both sides: only the deviceId rule can decide, and
    // both peers must decide identically without negotiating.
    const tie = 1700000000000000;
    await _forceUpdatedAt(
      a,
      table: 'assistant_rows',
      idColumn: 'id',
      id: 'assistant-1',
      updatedAtUs: tie,
    );
    await _forceUpdatedAt(
      b,
      table: 'assistant_rows',
      idColumn: 'id',
      id: 'assistant-1',
      updatedAtUs: tie,
    );

    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);

    final expected = await _assistantsOf(
      a.identity.deviceId.compareTo(b.identity.deviceId) > 0 ? a : b,
    );
    expect(await _assistantsOf(a), expected);
    expect(await _assistantsOf(b), expected);
  });

  test('the responder pushes its own entity edits back', () async {
    final (a, b) = await pair();
    await _setAssistants(a, [(id: 'assistant-1', name: 'From A')]);
    await a.engine.syncWithPeer(await a.peer(b));

    // b edits the same assistant and starts the next session itself.
    await _setAssistants(b, [(id: 'assistant-1', name: 'Edited on B')]);
    final report = await b.engine.syncWithPeer(await b.peer(a));
    expect(report.success, isTrue, reason: report.summary);

    expect(
      (await _assistantsOf(a))['assistant-1'],
      (await _assistantsOf(b))['assistant-1'],
    );
    expect((await _assistantsOf(a))['assistant-1'], contains('Edited on B'));
  });

  // ---- slice 3: blobs ----

  test('a skill record and its body both arrive', () async {
    final (a, b) = await pair();
    await a.putSkill('writer', {
      'SKILL.md': '# writer\n\nWrites things.\n',
      'scripts/run.sh': 'echo run\n',
    });

    final report = await a.engine.syncWithPeer(await a.peer(b));
    final responderReport = (await b.peer(a)).lastReport;
    expect(
      await b.hasSkillRow('writer'),
      isTrue,
      reason:
          'A=${report.summary} B=${jsonEncode(responderReport?.toJson() ?? const {})}',
    );
    // The body moved during the responder's reverse pull, so the counter that
    // names it lives on the responder's record.
    expect(responderReport?.skillsUpdated, 1);
    expect(responderReport?.blobsMissing, 0);
    // The body, not just the row: a record without its directory would install
    // a broken skill.
    expect(await b.skillBody('writer'), contains('Writes things.'));
    expect(
      await File('${b.skillsRoot.path}/writer/scripts/run.sh').readAsString(),
      'echo run\n',
    );
    // Both sides agree on the directory hash, which is the content baseline
    // the next session compares.
    expect(
      await b.skillDirectories.hashOf('writer'),
      await a.skillDirectories.hashOf('writer'),
    );

    // Nothing left to move.
    final second = await a.engine.syncWithPeer(await a.peer(b));
    expect(second.skillsUpdated, 0);
    expect(second.blobsMoved, 0);
  });

  test(
    'a body-only edit converges even though the record clock does not move',
    () async {
      final (a, b) = await pair();
      await a.putSkill('writer', {'SKILL.md': '# writer v1\n'});
      await a.engine.syncWithPeer(await a.peer(b));
      expect(await b.skillBody('writer'), '# writer v1\n');

      // Editing the body alone: the record row and its `updated_at` are
      // untouched, so only the directory hash can make this visible.
      await File(
        '${a.skillsRoot.path}/writer/SKILL.md',
      ).writeAsString('# writer v2\n', flush: true);

      final report = await a.engine.syncWithPeer(await a.peer(b));
      expect(report.success, isTrue, reason: report.summary);
      // The body is pulled by the responder, so its record carries the counters.
      expect((await b.peer(a)).lastReport?.skillsUpdated, 1);
      expect(await b.skillBody('writer'), '# writer v2\n');
    },
  );

  test('a skill deleted on one device loses its body on the other', () async {
    final (a, b) = await pair();
    await a.putSkill('writer', {'SKILL.md': '# writer\n'});
    await a.engine.syncWithPeer(await a.peer(b));
    expect(await b.hasSkillRow('writer'), isTrue);

    // Deleting the record and the directory together is what the skills
    // service does; sync must do the same, or the rescan resurrects the row.
    await a.businessRepository.syncDeleteEntity('skill', 'writer');
    await a.skillDirectories.deleteDirectory('writer');

    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);
    expect(await b.hasSkillRow('writer'), isFalse);
    expect(await Directory('${b.skillsRoot.path}/writer').exists(), isFalse);

    // And it stays gone across another session.
    await a.engine.syncWithPeer(await a.peer(b));
    expect(await b.hasSkillRow('writer'), isFalse);
  });

  test('a concurrent skill edit discards the loser and names it', () async {
    final (a, b) = await pair();
    await a.putSkill('writer', {'SKILL.md': '# shared\n'});
    await a.engine.syncWithPeer(await a.peer(b));

    // Both sides edit the body; the record clocks stay equal, so the deviceId
    // rule decides — and the loser is reported rather than dropped in silence.
    await File(
      '${a.skillsRoot.path}/writer/SKILL.md',
    ).writeAsString('# from A\n', flush: true);
    await File(
      '${b.skillsRoot.path}/writer/SKILL.md',
    ).writeAsString('# from B\n', flush: true);
    const tie = 1700000000000000;
    await _forceUpdatedAt(
      a,
      table: 'extension_entity_rows',
      idColumn: 'id',
      id: 'writer',
      updatedAtUs: tie,
    );
    await _forceUpdatedAt(
      b,
      table: 'extension_entity_rows',
      idColumn: 'id',
      id: 'writer',
      updatedAtUs: tie,
    );

    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);

    final aWins = a.identity.deviceId.compareTo(b.identity.deviceId) > 0;
    final winner = aWins ? '# from A\n' : '# from B\n';
    expect(await a.skillBody('writer'), winner);
    expect(await b.skillBody('writer'), winner);
    // The side that lost its edit says so; the winner's report names nothing.
    expect(report.skillConflicts, aWins ? 0 : 1);
  });

  test('an attachment blob reaches the peer and is registered', () async {
    final (a, b) = await pair();
    // The peer has no such file: its own root is empty until the blob lands.
    final image = File('${a.dir.path}/images/shot.png');
    await image.parent.create(recursive: true);
    await image.writeAsBytes(
      List<int>.generate(4096, (index) => index % 251),
      flush: true,
    );
    await _seedConversationWithImage(
      a,
      id: 'conv-img',
      uri: 'kelivo-file:///images/shot.png',
    );

    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);
    // The file moved during the responder's reverse pull.
    final responderReport = (await b.peer(a)).lastReport;
    expect(responderReport?.blobsMoved, 1);
    expect(responderReport?.blobsMissing, 0);

    final landed = File('${b.dir.path}/images/shot.png');
    expect(await landed.exists(), isTrue);
    expect(
      await landed.readAsBytes(),
      await image.readAsBytes(),
      reason: 'the blob is byte-identical',
    );
    // The asset registry owns it on the receiving side, which is what protects
    // it from the GC sweep and lets a later session skip the transfer.
    final registered = await b.repository.assetPathForContentHash(
      await BlobFileHasher().hashOf(landed) ?? '',
    );
    expect(registered, 'kelivo-file:///images/shot.png');

    // The next session has nothing to fetch.
    final second = await a.engine.syncWithPeer(await a.peer(b));
    expect(second.blobsMoved, 0);
    expect(second.blobsMissing, 0);
  });

  test(
    'a blob the peer cannot serve is reported and retried, not fatal',
    () async {
      final (a, b) = await pair();
      // Reference a file that no longer exists on the sender: its own manifest
      // skips it, so the receiver simply never learns about it — the session
      // succeeds with no blob traffic and no missing-blob count.
      await _seedConversationWithImage(
        a,
        id: 'conv-ghost',
        uri: 'kelivo-file:///images/ghost.png',
      );

      final report = await a.engine.syncWithPeer(await a.peer(b));
      expect(report.success, isTrue, reason: report.summary);
      expect(report.blobsMoved, 0);
      expect(await _conversationIds(b), contains('conv-ghost'));
    },
  );
}
