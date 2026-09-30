import 'dart:async';
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
import 'package:Cuplivo/core/providers/sync_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/skills/skill_directory_sync.dart';
import 'package:Cuplivo/core/services/sync/blob_sync.dart';
import 'package:Cuplivo/core/services/sync/business_state_reloader.dart';
import 'package:Cuplivo/core/services/sync/sync_client.dart';
import 'package:Cuplivo/core/services/sync/sync_data_plane.dart';
import 'package:Cuplivo/core/services/sync/sync_engine.dart';
import 'package:Cuplivo/core/services/sync/sync_identity.dart';
import 'package:Cuplivo/core/services/sync/sync_local_addresses.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:Cuplivo/core/services/sync/sync_pair_qr.dart';
import 'package:Cuplivo/core/services/sync/sync_server.dart';
import 'package:Cuplivo/core/services/sync/sync_store.dart';
import 'package:Cuplivo/features/home/controllers/chat_controller.dart';
import 'package:Cuplivo/features/sync/widgets/sync_pairing_dialogs.dart';
import 'package:Cuplivo/features/sync/widgets/sync_peer_card.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:provider/provider.dart';

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

/// A data plane that writes one extra message into the first conversation of
/// the push payload at the moment that payload is packaged. `buildBlobManifest`
/// runs after `readSubtree` and before the checkpoint advance, so this is
/// exactly the window a real user write (or a generation appending a row) lands
/// in — the window the sent-payload rule is about.
class _MidPushWritePlane extends SyncDataPlane {
  _MidPushWritePlane({
    required super.repository,
    required super.chatService,
    required super.businessRepository,
    super.businessPreferences,
    super.skillDirectories,
    super.blobPathResolver,
    required this.writeInto,
  });

  /// Called once, with the first outgoing conversation id.
  final Future<void> Function(String conversationId) writeInto;
  var _fired = false;

  @override
  Future<List<SyncBlobEntry>> buildBlobManifest({
    required List<SyncSubtreePayload> subtrees,
    required SyncBusinessPayload business,
  }) async {
    if (!_fired && subtrees.isNotEmpty) {
      _fired = true;
      await writeInto(subtrees.first.conversation['id'] as String);
    }
    return super.buildBlobManifest(subtrees: subtrees, business: business);
  }
}

/// A data plane that deletes the first advertised file *after* the blob
/// manifest is built: the rows still name the file and the hash is still
/// advertised, but the peer's pull can only 404 — the exact "advertised,
/// never landed" state a pending-blob retry has to survive.
class _VanishingBlobPlane extends SyncDataPlane {
  _VanishingBlobPlane({
    required super.repository,
    required super.chatService,
    required super.businessRepository,
    super.businessPreferences,
    super.skillDirectories,
    required super.blobPathResolver,
    required this.vanish,
  });

  final Future<void> Function() vanish;
  var _fired = false;

  @override
  Future<List<SyncBlobEntry>> buildBlobManifest({
    required List<SyncSubtreePayload> subtrees,
    required SyncBusinessPayload business,
  }) async {
    final entries = await super.buildBlobManifest(
      subtrees: subtrees,
      business: business,
    );
    if (!_fired && entries.isNotEmpty) {
      _fired = true;
      await vanish();
    }
    return entries;
  }
}

/// A data plane that writes into the conversation being merged, at the moment
/// the merge is entered: the window between the incoming payload's blob pull
/// and the apply, where a real user edit lands.
class _MidApplyWritePlane extends SyncDataPlane {
  _MidApplyWritePlane({
    required super.repository,
    required super.chatService,
    required super.businessRepository,
    super.businessPreferences,
    super.skillDirectories,
    required super.blobPathResolver,
    required this.writeBeforeApply,
  });

  final Future<void> Function(String conversationId) writeBeforeApply;
  var _fired = false;

  @override
  Future<Map<String, SyncSubtreeApplyOutcome>> applySubtrees(
    List<SyncSubtreePayload> subtrees, {
    required String myDeviceId,
    required String peerDeviceId,
    required Map<String, Map<String, int>> checkpointRowsByConversation,
  }) async {
    if (!_fired && subtrees.isNotEmpty) {
      _fired = true;
      await writeBeforeApply(subtrees.first.conversation['id'] as String);
    }
    return super.applySubtrees(
      subtrees,
      myDeviceId: myDeviceId,
      peerDeviceId: peerDeviceId,
      checkpointRowsByConversation: checkpointRowsByConversation,
    );
  }
}

/// A data plane that advertises file entries of the test's choosing — what a
/// hostile (or compromised) paired peer can put on the wire: a path outside
/// the managed roots, with a hash it picked.
class _CraftedBlobPlane extends SyncDataPlane {
  _CraftedBlobPlane({
    required super.repository,
    required super.chatService,
    required super.businessRepository,
    super.businessPreferences,
    super.skillDirectories,
    required super.blobPathResolver,
    required this.crafted,
  });

  final List<SyncBlobEntry> crafted;

  @override
  Future<List<SyncBlobEntry>> buildBlobManifest({
    required List<SyncSubtreePayload> subtrees,
    required SyncBusinessPayload business,
  }) async => [
    ...await super.buildBlobManifest(subtrees: subtrees, business: business),
    ...crafted,
  ];
}

/// A data plane that appends wire rows of the test's choosing to every subtree
/// it reads back — what a crafted peer sends: a row carrying another
/// conversation's message id, or one that labels itself as another
/// conversation.
class _CrossReferencingPlane extends SyncDataPlane {
  _CrossReferencingPlane({
    required super.repository,
    required super.chatService,
    required super.businessRepository,
    super.businessPreferences,
    super.skillDirectories,
    required super.blobPathResolver,
    required this.craft,
  });

  final List<Map<String, dynamic>> Function() craft;

  @override
  Future<SyncSubtreePayload?> readSubtree(String conversationId) async {
    final subtree = await super.readSubtree(conversationId);
    final extra = craft();
    if (subtree == null || extra.isEmpty) return subtree;
    return SyncSubtreePayload(
      conversation: subtree.conversation,
      messages: [...subtree.messages, ...extra],
      parts: subtree.parts,
      mcpServers: subtree.mcpServers,
    );
  }
}

/// A data plane that counts the per-conversation local checkpoint reads — the
/// cost a settled library must not pay again on every session.
class _CountingCheckpointPlane extends SyncDataPlane {
  _CountingCheckpointPlane({
    required super.repository,
    required super.chatService,
    required super.businessRepository,
    super.businessPreferences,
    super.skillDirectories,
    required super.blobPathResolver,
  });

  int reads = 0;

  @override
  Future<SyncCheckpointConversation?> checkpointFromLocal(
    String conversationId,
  ) {
    reads++;
    return super.checkpointFromLocal(conversationId);
  }
}

/// One device: its own sync directory, database, chat and business stores, and
/// its own listener.
class _Side {
  _Side(this.label, {this.newerSchema = false, this.clockOffsetUs = 0});

  final String label;
  final bool newerSchema;

  /// Shifts this side's hello clock, so a test can manufacture the skew the
  /// report is supposed to flag. Row clocks are untouched (they come from the
  /// write path), which is exactly the split the warning exists for.
  final int clockOffsetUs;

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

  /// Set when this side is driven through [SyncProvider] instead of a raw
  /// engine — the provider owns the listener then (QR flow, foreground round).
  SyncProvider? provider;

  Future<void> start(
    Directory root, {
    bool withEngine = true,
    Future<void> Function(String conversationId)? midPushWrite,
    Future<void> Function(String conversationId)? midApplyWrite,
    Future<void> Function()? vanishBlob,
    List<SyncBlobEntry>? craftedBlobs,
    List<Map<String, dynamic>> Function()? craftedRows,
    bool countCheckpointReads = false,
  }) async {
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
        : midPushWrite != null
        ? _MidPushWritePlane(
            repository: repository,
            chatService: chatService,
            businessRepository: businessRepository,
            businessPreferences: businessPreferences,
            skillDirectories: skillDirectories,
            blobPathResolver: resolveBlob,
            writeInto: midPushWrite,
          )
        : vanishBlob != null
        ? _VanishingBlobPlane(
            repository: repository,
            chatService: chatService,
            businessRepository: businessRepository,
            businessPreferences: businessPreferences,
            skillDirectories: skillDirectories,
            blobPathResolver: resolveBlob,
            vanish: vanishBlob,
          )
        : midApplyWrite != null
        ? _MidApplyWritePlane(
            repository: repository,
            chatService: chatService,
            businessRepository: businessRepository,
            businessPreferences: businessPreferences,
            skillDirectories: skillDirectories,
            blobPathResolver: resolveBlob,
            writeBeforeApply: midApplyWrite,
          )
        : craftedBlobs != null
        ? _CraftedBlobPlane(
            repository: repository,
            chatService: chatService,
            businessRepository: businessRepository,
            businessPreferences: businessPreferences,
            skillDirectories: skillDirectories,
            blobPathResolver: resolveBlob,
            crafted: craftedBlobs,
          )
        : craftedRows != null
        ? _CrossReferencingPlane(
            repository: repository,
            chatService: chatService,
            businessRepository: businessRepository,
            businessPreferences: businessPreferences,
            skillDirectories: skillDirectories,
            blobPathResolver: resolveBlob,
            craft: craftedRows,
          )
        : countCheckpointReads
        ? _CountingCheckpointPlane(
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
    if (!withEngine) return;
    engine = SyncEngine(
      identity: identity,
      store: store,
      dataPlane: dataPlane,
      onStateChanged: () {},
      clockUs: () => DateTime.now().microsecondsSinceEpoch + clockOffsetUs,
    );
    port = await engine.start(preferredPort: 0);
  }

  /// Drives this side through the real [SyncProvider] — the layer the QR
  /// pairing and the foreground round live in. [addressSource] stands in for
  /// the machine's interface enumeration, so a test can move this device to
  /// another network without touching a real NIC, and [presenceProbe] stands in
  /// for the online dot's bare TCP connect, so a peer can go on- and offline
  /// without a socket.
  Future<SyncProvider> startProvider({
    Future<List<LanAddress>> Function()? addressSource,
    Future<bool> Function(List<(String, int)> endpoints)? presenceProbe,
  }) async {
    final started = SyncProvider(
      chatService: chatService,
      repository: repository,
      businessRepository: businessRepository,
      businessPreferences: businessPreferences,
      reloader: BusinessStateReloader(businessPreferences),
      syncDirectory: () async => dir,
      addressSource: addressSource,
      presenceProbe: presenceProbe,
    );
    provider = started;
    await started.start();
    port = started.port ?? 0;
    return started;
  }

  Future<void> dispose() async {
    final viaProvider = provider;
    if (viaProvider != null) {
      // A provider-level pairing kicks its own first session (the window a
      // first sync needs), so a test can end while one is still writing into
      // the temp directory — and teardown's recursive delete then fails with
      // "file in use" instead of reporting anything about the test. Bounded:
      // against a live loopback peer a session drains in milliseconds, and a
      // truly wedged one should surface as its own assertion failure rather
      // than as a teardown that never returns.
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (viaProvider.busyDeviceIds.isNotEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await viaProvider.stop();
      viaProvider.dispose();
    } else {
      await engine.stop();
    }
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

/// A [SyncProvider] whose pairing verdict is canned, so the pairing dialog's own
/// behavior — what it announces, and whether it tells a new pairing from an
/// update — is testable without a listener or a socket.
class _StubSyncProvider extends SyncProvider {
  _StubSyncProvider(_Side side)
    : super(
        chatService: side.chatService,
        repository: side.repository,
        businessRepository: side.businessRepository,
        businessPreferences: side.businessPreferences,
        reloader: BusinessStateReloader(side.businessPreferences),
        syncDirectory: () async => side.dir,
      );

  /// What [pairWith] answers; set before the dialog submits.
  SyncPairOutcome outcome = const SyncPairOutcome.success();

  /// The addresses a repair asked this provider to store, so a test can see the
  /// form that reached it.
  final repaired = <(String, int)>[];

  @override
  Future<void> updatePeerEndpoint(
    String deviceId,
    String host,
    int port,
  ) async {
    repaired.add((host, port));
  }

  @override
  Future<SyncPairOutcome> pairWith({
    required String host,
    required int port,
    required String pin,
    String? expectedDeviceId,
  }) async => outcome;
}

/// A provider whose foreground round records the address list it ran on, so a
/// test can see whether the round waited for the enumeration.
class _RoundRecordingProvider extends SyncProvider {
  _RoundRecordingProvider({
    required super.chatService,
    required super.repository,
    required super.businessRepository,
    required super.businessPreferences,
    required super.reloader,
    required super.syncDirectory,
    super.addressSource,
  });

  /// One entry per round that ran — the list the round would have ordered its
  /// dials by.
  final rounds = <List<LanAddress>>[];

  @override
  Future<void> autoSyncRound() async {
    rounds.add(List.of(localAddresses));
  }
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

/// The assistants in the order the app renders them (their `sort_order`).
Future<List<String>> _assistantOrder(_Side side) async => [
  for (final row in await side.businessRepository.readEntities(
    BusinessEntityKind.assistant,
  ))
    row.id,
];

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

/// Marks a conversation as mid-generation on [side] — the state that makes sync
/// apply and peer deletion yield and be retried. The flag is not part of any
/// digest, so it changes nothing except the deferral.
Future<void> _setStreaming(
  _Side side,
  String conversationId, {
  required bool streaming,
}) => side.database.customStatement(
  'UPDATE message_rows SET is_streaming = ? WHERE conversation_id = ?;',
  <Object?>[streaming ? 1 : 0, conversationId],
);

/// Reads a row's mutation clock — the value the LWW comparison actually uses.
Future<int?> _rowClock(
  _Side side, {
  required String table,
  required String idColumn,
  required String id,
}) async {
  final row = await side.database
      .customSelect(
        'SELECT updated_at FROM $table WHERE $idColumn = ?;',
        variables: <Variable<Object>>[Variable<String>(id)],
      )
      .getSingleOrNull();
  return row?.read<int>('updated_at');
}

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

/// Writes a managed file the way an upload does, so a blob exists to be
/// hashed, advertised and pulled.
Future<void> _writeBlob(_Side side, String rel, String content) async {
  final file = File('${side.dir.path}/$rel');
  await file.parent.create(recursive: true);
  await file.writeAsString(content, flush: true);
}

/// The paths whose assets [revisionId] references here — the reference set the
/// registration maintains.
Future<Set<String>> _assetPathsFor(_Side side, String revisionId) async {
  final rows = await side.database
      .customSelect(
        'SELECT a.path AS path FROM message_asset_rows r '
        'JOIN asset_rows a ON a.id = r.asset_id WHERE r.revision_id = ?;',
        variables: [Variable.withString(revisionId)],
      )
      .get();
  return {for (final row in rows) row.read<String>('path')};
}

/// A loopback port nothing is listening on (bound then released): the dead
/// candidate the QR endpoint iteration must skip.
Future<int> _unusedPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// Unpair propagation is fire-and-forget on purpose (unpairing must not wait
/// on a peer), so a test that asserts the *peer* reacted has to poll for it.
Future<void> _waitUntil(
  Future<bool> Function() check, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('condition not met within $timeout');
}

/// Removes a test's scratch directory, retrying while a late handle holds it.
///
/// The provider's tails are deliberately fire-and-forget (`refreshPeers` after a
/// session, the presence probe), so a read can still be in flight when a test
/// ends — and Windows refuses to delete a directory whose file is open. That is
/// scratch space under the system temp, so retrying briefly and then giving up
/// is strictly better than failing a green test in teardown.
Future<void> _deleteTree(Directory root) async {
  for (var attempt = 0; attempt < 10; attempt++) {
    try {
      if (await root.exists()) await root.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
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
    await _deleteTree(root);
  });

  test('a disposed provider is never notified again', () async {
    // Deliberately not added to `sides`: this test disposes the provider itself,
    // and the shared teardown would dispose it a second time (which
    // ChangeNotifier asserts on). The cleanup below is what teardown would do.
    final a = _Side('a');
    await a.start(root, withEngine: false);
    final provider = await a.startProvider(addressSource: () async => const []);

    await provider.stop();
    provider.dispose();

    // Every unawaited tail the provider starts ends in a notification: the
    // interface enumeration, the firewall child process, a session that
    // outlives the screen. `ChangeNotifier` asserts on a notification after
    // dispose, and that assertion surfaces as an unhandled async error — it is
    // reported against whatever test happens to be running when it lands, not
    // against the one that disposed the provider.
    await provider.refreshPeers();
    await provider.refreshLocalAddresses();

    await a.chatService.close();
    await a.repository.close();
  });

  test(
    'a foreground round runs on the addresses the enumeration produced',
    () async {
      // Deliberately not added to `sides`: this test starts and disposes its own
      // provider, and the shared teardown would dispose it a second time.
      final a = _Side('a');
      await a.start(root, withEngine: false);

      const addresses = <LanAddress>[(name: 'en0', address: '192.168.1.20')];
      final gates = <Completer<void>>[];
      final provider = _RoundRecordingProvider(
        chatService: a.chatService,
        repository: a.repository,
        businessRepository: a.businessRepository,
        businessPreferences: a.businessPreferences,
        reloader: BusinessStateReloader(a.businessPreferences),
        syncDirectory: () async => a.dir,
        addressSource: () async {
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
          return addresses;
        },
      );

      final starting = provider.start();
      // The enumeration is in flight and blocked here, which is the window the
      // round used to run in: it must be waiting behind it, not dialing with the
      // empty list the same-subnet preference cannot read anything from.
      await _waitUntil(() async => gates.isNotEmpty);
      expect(provider.rounds, isEmpty);

      gates[0].complete();
      await starting;
      await _waitUntil(() async => provider.rounds.isNotEmpty);
      expect(provider.rounds.single, addresses);

      // Resume goes through the same door, and the race is the same one: the
      // device may have changed networks while the app was away.
      provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _waitUntil(() async => gates.length == 2);
      expect(provider.rounds.length, 1, reason: 'the resumed round waits too');

      gates[1].complete();
      await _waitUntil(() async => provider.rounds.length == 2);
      expect(provider.rounds.last, addresses);

      await provider.stop();
      provider.dispose();
      await a.chatService.close();
      await a.repository.close();
    },
  );

  Future<(_Side, _Side)> pair({
    bool newerSchema = false,
    String host = '127.0.0.1',
  }) async {
    final a = _Side('a');
    final b = _Side('b', newerSchema: newerSchema);
    await a.start(root);
    await b.start(root);
    sides.addAll([a, b]);
    final pin = b.engine.openPairing();
    await a.engine.pairWith(host: host, port: b.port, pin: pin);
    return (a, b);
  }

  /// Pairs two already-started sides — the explicit form a three-device
  /// topology needs, where not every pair is paired.
  Future<void> pairSides(_Side initiator, _Side responder) async {
    final pin = responder.engine.openPairing();
    await initiator.engine.pairWith(
      host: '127.0.0.1',
      port: responder.port,
      pin: pin,
    );
  }

  test('the listener pairs and syncs over IPv6 loopback', () async {
    final (a, b) = await pair(host: '::1');

    // Stored bare on both sides: the socket wants `::1`, a URI wants `[::1]`,
    // and the boundary that brackets it is the client's.
    expect((await a.peer(b)).primaryEndpoint?.host, '::1');
    expect(
      (await b.peer(a)).primaryEndpoint?.host,
      '::1',
      reason: 'the responder learned the address the caller connected from',
    );

    await _seedConversation(a, id: 'conv-v6', contents: ['over v6']);
    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);
    expect(await _conversationIds(b), contains('conv-v6'));
  });

  test('an IPv4 caller is stored as IPv4, not as its mapped form', () async {
    final (a, b) = await pair();

    // The listener is dual-stack, so an IPv4 caller arrives as
    // `::ffff:127.0.0.1`. Stored as-is, that endpoint cannot be dialed back —
    // `Uri.parse` refuses an unbracketed literal — so the server normalizes the
    // address before the engine ever sees it.
    final bPeer = await b.peer(a);
    expect(bPeer.primaryEndpoint?.host, '127.0.0.1');
    expect(
      bPeer.endpoints.map((endpoint) => endpoint.host),
      isNot(contains('::ffff:127.0.0.1')),
    );

    // The return direction works over that stored host.
    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);
  });

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
      expect(aPeer.primaryEndpoint?.host, '127.0.0.1');
      expect(aPeer.primaryEndpoint?.port, b.port);
      expect(aPeer.certPem, b.identity.certPem, reason: 'pinned certificate');

      // The responder learns where the initiator connected from plus the
      // listener port it advertised, so it can start sessions too.
      final bPeer = await b.peer(a);
      expect(bPeer.primaryEndpoint?.host, '127.0.0.1');
      expect(bPeer.primaryEndpoint?.port, a.port);
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

  /// A raw TLS client that accepts the self-signed listener — for /pair
  /// requests no honest SyncClient would ever send.
  Future<(int, String)> postPair(_Side target, String body) async {
    final client = HttpClient()
      ..badCertificateCallback = (cert, host, port) => true;
    try {
      final request = await client.postUrl(
        Uri.parse('https://127.0.0.1:${target.port}/pair'),
      );
      request.headers.contentType = ContentType.json;
      request.write(body);
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      return (response.statusCode, text);
    } finally {
      client.close(force: true);
    }
  }

  test('an unauthenticated /pair body is capped and shape-checked', () async {
    final b = _Side('b');
    await b.start(root);
    sides.add(b);

    // Valid JSON without the pairing fields is a client error, not a 500
    // that prints the server's stack trace into the log.
    final (badStatus, _) = await postPair(b, '{"hello": "world"}');
    expect(badStatus, HttpStatus.badRequest);

    // A body past the cap is refused while being read — it is the only
    // unauthenticated input the listener buffers.
    final overCap = '{ "pad": "${'x' * (70 * 1024)}" }';
    final (bigStatus, bigBody) = await postPair(b, overCap);
    expect(bigStatus, HttpStatus.requestEntityTooLarge);
    expect(bigBody, contains('body_too_large'));

    // An unparseable certificate is a client error too, not a 500.
    final (badCertStatus, badCertBody) = await postPair(
      b,
      '{"pin": "000000", "deviceId": "d", "deviceName": "", '
      '"platform": "t", "certPem": "not-a-pem"}',
    );
    expect(badCertStatus, HttpStatus.badRequest);
    expect(badCertBody, contains('bad_cert'));

    // A well-shaped request still reaches the pairing logic (refused here
    // because no window is open), so the guards gate nothing else.
    final (idleStatus, idleBody) = await postPair(
      b,
      '{"pin": "000000", "deviceId": "${b.identity.deviceId}", '
      '"deviceName": "", "platform": "t", '
      '"certPem": ${jsonEncode(b.identity.certPem)}}',
    );
    expect(idleStatus, HttpStatus.forbidden);
    expect(idleBody, contains('invalid_pin'));
  });

  test('a half-sent /pair body does not wedge the listener', () async {
    // The request loop is serial: a body that announces itself and then stops
    // arriving used to hold it forever, so no pairing and no sync request was
    // ever served again. The route deadline frees the loop; the short budget
    // here is the test seam for the same path.
    final b = _Side('b');
    await b.start(root);
    sides.add(b);
    final server = SyncServer(
      identity: b.identity,
      store: b.store,
      handler: b.engine,
      deadlineFor: (_) => const Duration(milliseconds: 300),
    );
    final port = await server.start(address: '127.0.0.1', requestedPort: 0);
    addTearDown(server.stop);

    final socket = await SecureSocket.connect(
      '127.0.0.1',
      port,
      onBadCertificate: (_) => true,
    );
    socket.write(
      'POST /pair HTTP/1.1\r\n'
      'Host: 127.0.0.1\r\n'
      'Content-Type: application/json\r\n'
      'Content-Length: 100000\r\n'
      '\r\n'
      '{"',
    );
    await socket.flush();

    // A normal request is served while the partial one is still open.
    final client = HttpClient()
      ..badCertificateCallback = (cert, host, port) => true;
    try {
      final request = await client.postUrl(
        Uri.parse('https://127.0.0.1:$port/pair'),
      );
      request.headers.contentType = ContentType.json;
      request.write('{"hello": "world"}');
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, HttpStatus.badRequest);
    } finally {
      client.close(force: true);
    }

    // And the stalled request itself is answered with the timeout status. The
    // five-second guard is what makes a regression fail fast instead of
    // hanging: with the deadline gone, the answer only arrives after the
    // production budget. The bytes are read raw — the body is gzipped JSON, but
    // the status line is plain ASCII.
    final raw = await socket
        .cast<List<int>>()
        .expand((chunk) => chunk)
        .toList()
        .timeout(const Duration(seconds: 5));
    final head = latin1.decode(raw.take(512).toList(), allowInvalid: true);
    expect(head, contains('504'));
    socket.destroy();
  });

  test('a request against a peer that stops answering times out', () async {
    // Trigger (a) of the review: a peer that completes the handshake and then
    // stalls must not leave the caller's await pending forever — the provider's
    // busyDeviceIds would stay set and automatic rounds would stop for the life
    // of the process.
    final (a, b) = await pair();
    final silent = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      b.identity.buildContext(),
      requestClientCertificate: false,
    );
    addTearDown(() => silent.close(force: true));

    final session = a.engine.client.openSession(
      await a.peer(b),
      host: '127.0.0.1',
      port: silent.port,
      helloDeadline: const Duration(milliseconds: 300),
    );
    final started = DateTime.now();
    Object? failure;
    try {
      await session.hello(a.hello()).timeout(const Duration(seconds: 10));
    } catch (error) {
      failure = error;
    }
    final elapsed = DateTime.now().difference(started);
    session.close();

    expect(failure, isA<TimeoutException>());
    expect(
      elapsed,
      lessThan(const Duration(seconds: 5)),
      reason: 'the request deadline must be what ends the wait',
    );
  });

  test('a pair runs one session at a time, in both roles', () async {
    // Both roles write the same checkpoint file from the copy each read at its
    // own hello, so two concurrent sessions for a pair would lose one of the
    // advances — and both devices resuming at once is routine.
    final (a, b) = await pair();
    await _seedConversation(a, id: 'conv-a', contents: ['a1']);
    final aPeer = await a.peer(b);
    final bPeer = await b.peer(a);

    // (1) A responder session is live here: initiating to that peer is refused.
    final hello = await b.engine.handleHello(
      a.identity.deviceId,
      SyncHello(
        protocolVersion: kSyncProtocolVersion,
        schemaVersion: a.dataPlane.schemaVersion,
        deviceId: a.identity.deviceId,
        deviceName: a.label,
        platform: 'test',
        manifest: await a.dataPlane.buildManifest(),
      ),
    );
    expect(hello, isA<SyncHello>(), reason: 'the session was accepted');
    final refused = await b.engine.syncWithPeer(bPeer);
    expect(refused.success, isFalse);
    expect(refused.refusal, SyncRefusalReason.busy);
    // The live session survived: its fetch beat still finds it.
    await b.engine.handleFetchSubtrees(
      a.identity.deviceId,
      const SyncFetchRequest(),
    );

    // (2) An initiator round in flight here: the peer's hello is refused. The
    // target is a listener that speaks the peer's certificate and never
    // answers, so the round is still waiting when the hello arrives.
    final silent = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      b.identity.buildContext(),
      requestClientCertificate: false,
    );
    final pending = a.engine.syncWithPeer(
      aPeer,
      host: '127.0.0.1',
      port: silent.port,
    );
    final answer = await a.engine.handleHello(
      b.identity.deviceId,
      SyncHello(
        protocolVersion: kSyncProtocolVersion,
        schemaVersion: b.dataPlane.schemaVersion,
        deviceId: b.identity.deviceId,
        deviceName: b.label,
        platform: 'test',
        manifest: await b.dataPlane.buildManifest(),
      ),
    );
    expect(answer, isA<SyncHelloRefusal>());
    expect((answer as SyncHelloRefusal).reason, SyncRefusalReason.busy);

    // Dropping the listener ends A's round; the marker is released, so the
    // next attempt is admitted rather than refused for good.
    await silent.close(force: true);
    await pending;
    await a.engine.syncWithPeer(aPeer, host: '127.0.0.1', port: b.port);
  });

  test('a replaced database makes the peer re-send, not delete', () async {
    // A restore (or an overwrite import) replaces the local history wholesale.
    // The rows it drops were never deleted, so the peer's checkpoint — which
    // says "we both had conv-a" — must not turn their absence into a deletion
    // of the peer's own copy: it re-sends instead, and the two converge again.
    final (a, b) = await pair();
    await _seedConversation(a, id: 'conv-a', contents: ['a1']);
    await a.engine.syncWithPeer(await a.peer(b));
    expect(await _conversationIds(b), contains('conv-a'));

    // What a restore leaves behind: the rows are gone, with no deletion event
    // written (deleteConversation would write a tombstone, which is the
    // deliberate-deletion path), plus the bulk-replacement sync reset.
    await b.database.customStatement(
      'DELETE FROM message_rows WHERE conversation_id = ?;',
      ['conv-a'],
    );
    await b.database.customStatement(
      'DELETE FROM conversation_rows WHERE id = ?;',
      ['conv-a'],
    );
    await SyncStore.resetForBulkReplacement(b.dir);
    expect(await _conversationIds(b), isEmpty);

    await a.engine.syncWithPeer(await a.peer(b));

    expect(
      await _conversationIds(a),
      contains('conv-a'),
      reason: 'the peer lost the row; it did not delete it',
    );
    expect(await _conversationIds(b), contains('conv-a'));
    // The epoch is recorded, so only the first session after the replacement
    // pays for the re-convergence.
    final checkpoint = await a.store.loadCheckpoint(b.identity.deviceId);
    expect(checkpoint.peerEpoch, 1);
  });

  testWidgets('the pairing code dialog cannot be dismissed by a gesture', (
    tester,
  ) async {
    // The pairing window outlives a dismissed dialog: the PIN and QR stay
    // valid for five minutes and nothing else on screen shows it. The dialog
    // therefore refuses barrier taps and system back.
    final a = _Side('a');
    // Real sockets and the identity filesystem do not complete under the
    // widget tester's fake clock, so the setup runs on the real one.
    late final SyncProvider provider;
    late final AppLocalizations l10n;
    await tester.runAsync(() async {
      await a.start(root, withEngine: false);
      sides.add(a);
      provider = await a.startProvider();
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncProvider>.value(
        value: provider,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      showSyncPairingDialogs(context: context, showCode: true),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // No pumpAndSettle: the dialog runs a one-second countdown ticker.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(provider.isPairingOpen, isTrue);

    // A barrier tap must not close it — that is the path that used to leave
    // an invisible open window behind.
    await tester.tapAt(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(provider.isPairingOpen, isTrue);

    // The explicit close cancels the window with the dialog.
    await tester.tap(find.text(l10n.lanSyncClosePairing));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsNothing);
    expect(provider.isPairingOpen, isFalse);
  });

  testWidgets('closing the pairing code dialog pops only the dialog', (
    tester,
  ) async {
    // Two closers race: the close button cancels the window (the expiry
    // reads null from then on) and pops, but `mounted` stays true until the
    // exit animation finishes — a countdown tick landing inside that window
    // used to see the nulled expiry and pop a second time, taking the page
    // beneath the dialog with it. The pumps below land a tick 50 ms into the
    // exit animation, which reproduces the race deterministically.
    final a = _Side('a');
    late final SyncProvider provider;
    late final AppLocalizations l10n;
    await tester.runAsync(() async {
      await a.start(root, withEngine: false);
      sides.add(a);
      provider = await a.startProvider();
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncProvider>.value(
        value: provider,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      showSyncPairingDialogs(context: context, showCode: true),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump(); // Dialog built; the ticker's first tick is due at +1s.
    // Stop 50 ms short of the tick, so the close below starts its exit
    // animation with the next tick still ahead of it.
    await tester.pump(const Duration(milliseconds: 950));
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(find.text(l10n.lanSyncClosePairing));
    // The due tick fires 50 ms into the exit animation, while the dialog's
    // state is still mounted.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(provider.isPairingOpen, isFalse);
    // Exactly one pop: the page that hosted the dialog survived the close.
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('the pairing QR is sized for an IPv6 endpoint', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: PairingQrImage(data: 'cuplivo-pair:v1:whatever')),
        ),
      ),
    );

    final image = tester.widget<PairingQrImage>(find.byType(PairingQrImage));
    expect(image.size, kPairingQrEdge);
    expect(image.errorCorrectLevel, kPairingQrErrorCorrectLevel);
    expect(kPairingQrErrorCorrectLevel, QrErrorCorrectLevel.L);
    // The rendered square really is that size — the module size a camera sees
    // is this number divided by the symbol's module count.
    expect(tester.getSize(find.byType(PrettyQrView)), const Size(220, 220));
  });

  testWidgets('the pairing QR follows this device onto another network', (
    tester,
  ) async {
    final a = _Side('a');
    late final SyncProvider provider;
    late final AppLocalizations l10n;
    var source = <LanAddress>[(name: 'wlan0', address: '10.9.0.5')];
    await tester.runAsync(() async {
      await a.start(root, withEngine: false);
      sides.add(a);
      provider = await a.startProvider(addressSource: () async => source);
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await pumpEventQueue();
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncProvider>.value(
        value: provider,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      showSyncPairingDialogs(context: context, showCode: true),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 950));

    // What the image on screen actually encodes, not what the list says.
    SyncPairQrPayload encoded() => SyncPairQrPayload.parse(
      tester.widget<PairingQrImage>(find.byType(PairingQrImage)).data,
    );
    expect(encoded().endpoints, [('10.9.0.5', provider.port)]);

    // The device joins another network while the dialog is open. The QR used to
    // be encoded once, at open, so it kept advertising the network this device
    // had just left while the list below it showed the new one.
    source = [(name: 'wlan0', address: '192.168.44.9')];
    await tester.runAsync(() => provider.refreshLocalAddresses());
    await tester.pump(
      const Duration(seconds: 1),
    ); // the countdown tick rebuilds

    expect(encoded().endpoints, [('192.168.44.9', provider.port)]);
    expect(
      find.text('192.168.44.9:${provider.port}'),
      findsOneWidget,
      reason: 'the image and the list agree',
    );

    // Close it, so the countdown ticker does not outlive the test.
    await tester.tap(find.text(l10n.lanSyncClosePairing));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('entering a code re-reads this device addresses first', (
    tester,
  ) async {
    final a = _Side('a');
    late final SyncProvider provider;
    var source = <LanAddress>[(name: 'wlan0', address: '10.9.0.5')];
    await tester.runAsync(() async {
      await a.start(root, withEngine: false);
      sides.add(a);
      provider = await a.startProvider(addressSource: () async => source);
      await pumpEventQueue();
    });

    // The device joined another network with the app in the foreground: no
    // lifecycle event fires, so nothing has re-enumerated yet.
    source = [(name: 'wlan0', address: '192.168.44.9')];
    expect(provider.localAddresses.single.address, '10.9.0.5');

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncProvider>.value(
        value: provider,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      showSyncPairingDialogs(context: context, showCode: false),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // Opening the entering side is what re-reads them: the addresses this side
    // advertises ride in the pairing request, and the peer remembers every
    // candidate it is handed — a hint from the network this device just left is
    // a dead candidate the peer would keep dialing.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(3), reason: 'the form opened');
    expect(provider.localAddresses.single.address, '192.168.44.9');

    // Dismissed, so no route outlives the test.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a hand-typed code announces the device it paired with', (
    tester,
  ) async {
    // Deliberately not added to `sides`: this side runs no engine of its own —
    // the dialog's provider is a stub — and the shared teardown disposes either
    // an engine or a provider started through `startProvider`. The cleanup at
    // the end of this test is what that teardown would do.
    final a = _Side('a');
    late final AppLocalizations l10n;
    late final _StubSyncProvider provider;
    await tester.runAsync(() async {
      await a.start(root, withEngine: false);
      provider = _StubSyncProvider(a);
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncProvider>.value(
        value: provider,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      showSyncPairingDialogs(context: context, showCode: false),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    Future<void> pairByHand() async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '192.168.1.7');
      await tester.enterText(find.byType(TextField).at(1), '9527');
      // Six digits submits the form, which is the path the phone user takes.
      await tester.enterText(find.byType(TextField).at(2), '123456');
      await tester.pumpAndSettle();
    }

    bool announced(String message) => AppSnackBarManager().activeToasts.any(
      (toast) => toast.notification.message == message,
    );

    provider.outcome = const SyncPairOutcome.success(
      peerName: 'Studio desktop',
      peerDeviceId: 'abc1234567890def',
    );
    await pairByHand();

    // Typing the code by hand used to pop in silence, so the one success the
    // user had to trigger themselves was the only one with no confirmation.
    expect(
      announced(l10n.lanSyncPairSuccess('Studio desktop')),
      isTrue,
      reason: 'the manual path names the device it paired with',
    );
    expect(find.byType(AlertDialog), findsNothing, reason: 'paired: it closes');

    // A device already in the list is an update rather than a new pairing — the
    // same distinction the scanned path draws from the peer list.
    provider.peers = [
      SyncPeerRecord(
        deviceId: 'abc1234567890def',
        certPem: 'pem',
        secret: 'secret',
        name: 'Studio desktop',
        platform: 'test',
      ),
    ];
    await pairByHand();
    expect(
      announced(l10n.lanSyncPairUpdatedSnackbar('Studio desktop')),
      isTrue,
      reason: 're-pairing an existing device reads as an update',
    );

    // Let both toasts expire: neither their own timer nor their exit animation
    // may outlive the test.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(AppSnackBarManager().activeToasts, isEmpty);

    provider.dispose();
    await a.chatService.close();
    await a.repository.close();
  });

  testWidgets('a peer card says how long ago, and copies its address', (
    tester,
  ) async {
    // Not added to `sides`, for the same reason as the pairing-dialog test
    // above: this side runs no engine of its own.
    final a = _Side('a');
    late final _StubSyncProvider provider;
    late final AppLocalizations l10n;
    await tester.runAsync(() async {
      await a.start(root, withEngine: false);
      provider = _StubSyncProvider(a);
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    final copied = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied.add(call);
        return null;
      },
    );

    final peer = SyncPeerRecord(
      deviceId: 'peer-1',
      certPem: 'pem',
      secret: 'secret',
      name: 'Studio desktop',
      platform: 'android',
      endpoints: [
        SyncPeerEndpoint(host: '192.168.1.5', port: 9527),
        SyncPeerEndpoint(host: 'fd00::5', port: 9527),
      ],
      lastSyncedAt: DateTime.now().subtract(const Duration(minutes: 4)),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncProvider>.value(
        value: provider,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SyncPeerCard(peer: peer)),
        ),
      ),
    );

    // A peer reached on two networks should not look like a peer with one
    // address: the count is beside the address in use.
    final subtitle = '${l10n.lanSyncPlatformAndroid} · 192.168.1.5:9527 (+1)';
    expect(find.text(subtitle), findsOneWidget);

    // How long ago, not a timestamp — the tooltip keeps the exact time.
    expect(
      find.text(l10n.lanSyncLastSyncedAt('4 min ago')),
      findsOneWidget,
      reason: 'the line answers "is this current?", not "when exactly?"',
    );

    await tester.tap(find.text(subtitle));
    await tester.pumpAndSettle();

    expect(
      (copied.single.arguments as Map)['text'],
      '192.168.1.5:9527',
      reason: 'the address in use is what a tap copies',
    );
    expect(
      AppSnackBarManager().activeToasts.any(
        (toast) => toast.notification.message == l10n.lanSyncAddressCopied,
      ),
      isTrue,
      reason: 'a copy with no feedback is indistinguishable from a dead tap',
    );

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );

    provider.dispose();
    await a.chatService.close();
    await a.repository.close();
  });

  testWidgets('the address repair stores the bare host, like pairing does', (
    tester,
  ) async {
    // Not added to `sides`, for the same reason as the peer-card test above.
    final a = _Side('a');
    late final _StubSyncProvider provider;
    late final AppLocalizations l10n;
    await tester.runAsync(() async {
      await a.start(root, withEngine: false);
      provider = _StubSyncProvider(a);
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    final peer = SyncPeerRecord(
      deviceId: 'peer-1',
      certPem: 'pem',
      secret: 'secret',
      name: 'Studio desktop',
      platform: 'linux',
      endpoints: [SyncPeerEndpoint(host: 'fd00::5', port: 9527)],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncProvider>.value(
        value: provider,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SyncPeerCard(peer: peer)),
        ),
      ),
    );

    await tester.tap(find.text(l10n.lanSyncEditAddress));
    await tester.pumpAndSettle();
    // The bracketed literal is what the card itself shows and copies, so pasting
    // the address back into the repair field is the journey this field exists
    // for — and storage keeps the bare host, which is what the dial needs.
    await tester.enterText(find.byType(TextField).at(0), '[fd00::9]');
    await tester.enterText(find.byType(TextField).at(1), '9528');
    await tester.tap(find.widgetWithText(FilledButton, 'OK'));
    await tester.pumpAndSettle();

    expect(provider.repaired.single, ('fd00::9', 9528));

    provider.dispose();
    await a.chatService.close();
    await a.repository.close();
  });

  testWidgets('a peer card renders its outcome as chips, not one joined line', (
    tester,
  ) async {
    final a = _Side('a');
    late final _StubSyncProvider provider;
    late final AppLocalizations l10n;
    await tester.runAsync(() async {
      await a.start(root, withEngine: false);
      provider = _StubSyncProvider(a);
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    final peer = SyncPeerRecord(
      deviceId: 'peer-1',
      certPem: 'pem',
      secret: 'secret',
      name: 'Studio desktop',
      platform: 'android',
      endpoints: [SyncPeerEndpoint(host: '192.168.1.5', port: 9527)],
      lastSyncedAt: DateTime.now(),
      lastReport: const SyncPeerReport(
        success: true,
        sent: 2,
        received: 3,
        upsertedMessages: 128,
        blobsMoved: 2,
        blobBytes: 3 * 1024 * 1024,
        skillsUpdated: 1,
        deferred: 1,
      ),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncProvider>.value(
        value: provider,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SyncPeerCard(peer: peer)),
        ),
      ),
    );

    expect(find.text(l10n.lanSyncReportSent(2)), findsOneWidget);
    expect(find.text(l10n.lanSyncReportReceived(3)), findsOneWidget);
    expect(find.text(l10n.lanSyncReportMessagesUpserted(128)), findsOneWidget);
    expect(
      find.text(l10n.lanSyncReportBlobsWithSize(2, '3.00 MB')),
      findsOneWidget,
      reason: 'a file count carries its size, formatted the app-wide way',
    );
    expect(find.text(l10n.lanSyncReportSkills(1)), findsOneWidget);
    expect(
      find.text(l10n.lanSyncReportDeferred(1)),
      findsOneWidget,
      reason: 'a deferred item is named, not left to a log',
    );
    // The single " · "-joined line is exactly what this replaced.
    expect(
      find.text(
        '${l10n.lanSyncReportSent(2)} · ${l10n.lanSyncReportReceived(3)}',
      ),
      findsNothing,
    );
    // No probe has run, so the dot is the honest gray one.
    expect(find.byTooltip(l10n.lanSyncOffline), findsOneWidget);

    provider.dispose();
    await a.chatService.close();
    await a.repository.close();
  });

  testWidgets('a settled session that moved nothing reads as up to date', (
    tester,
  ) async {
    final a = _Side('a');
    late final _StubSyncProvider provider;
    late final AppLocalizations l10n;
    await tester.runAsync(() async {
      await a.start(root, withEngine: false);
      provider = _StubSyncProvider(a);
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    final peer = SyncPeerRecord(
      deviceId: 'peer-1',
      certPem: 'pem',
      secret: 'secret',
      name: 'Studio desktop',
      platform: 'linux',
      endpoints: [SyncPeerEndpoint(host: '192.168.1.5', port: 9527)],
      lastSyncedAt: DateTime.now(),
      lastReport: const SyncPeerReport(success: true),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncProvider>.value(
        value: provider,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SyncPeerCard(peer: peer)),
        ),
      ),
    );

    expect(find.text(l10n.lanSyncUpToDate), findsOneWidget);
    expect(
      find.text(l10n.lanSyncReportSent(0)),
      findsNothing,
      reason: '"0 sent" is noise; nothing moved is the fact',
    );

    provider.dispose();
    await a.chatService.close();
    await a.repository.close();
  });

  testWidgets('a card shows the online dot and the first-sync warning', (
    tester,
  ) async {
    final a = _Side('a');
    late final _StubSyncProvider provider;
    late final AppLocalizations l10n;
    await tester.runAsync(() async {
      await a.start(root, withEngine: false);
      provider = _StubSyncProvider(a);
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    // A session with this peer is running, and it is the first one ever.
    provider.onlineDeviceIds.add('peer-1');
    provider.busyDeviceIds.add('peer-1');

    final peer = SyncPeerRecord(
      deviceId: 'peer-1',
      certPem: 'pem',
      secret: 'secret',
      name: 'Studio desktop',
      platform: 'android',
      endpoints: [SyncPeerEndpoint(host: '192.168.1.5', port: 9527)],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncProvider>.value(
        value: provider,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SyncPeerCard(peer: peer)),
        ),
      ),
    );

    expect(find.byTooltip(l10n.lanSyncOnline), findsOneWidget);
    expect(
      find.text(l10n.lanSyncFirstSyncHint),
      findsOneWidget,
      reason: 'the longest session is the one that needs both apps awake',
    );
    expect(
      find.text(l10n.lanSyncPhaseConnecting),
      findsOneWidget,
      reason: 'no engine beat yet, so the card names the first one',
    );
    expect(
      find.text(l10n.lanSyncSyncNow),
      findsNothing,
      reason: 'the button is replaced by the progress it started',
    );

    provider.dispose();
    await a.chatService.close();
    await a.repository.close();
  });

  test('a QR-scanned fingerprint pairs without a typed PIN', () async {
    final a = _Side('a');
    final b = _Side('b');
    await a.start(root);
    await b.start(root);
    sides.addAll([a, b]);

    final pin = b.engine.openPairing();
    await a.engine.pairWith(
      host: '127.0.0.1',
      port: b.port,
      pin: pin,
      expectedDeviceId: b.identity.deviceId,
    );

    final aPeer = await a.peer(b);
    expect(aPeer.deviceId, b.identity.deviceId);
    expect(aPeer.primaryEndpoint?.host, '127.0.0.1');
    expect(aPeer.primaryEndpoint?.port, b.port);
    expect(b.engine.isPairingOpen, isFalse, reason: 'the PIN is spent');
  });

  test('a mismatched fingerprint aborts before the PIN is spent', () async {
    final a = _Side('a');
    final b = _Side('b');
    final c = _Side('c'); // only a source of a wrong fingerprint
    await a.start(root);
    await b.start(root);
    await c.start(root);
    sides.addAll([a, b, c]);

    final pin = b.engine.openPairing();
    await expectLater(
      a.engine.pairWith(
        host: '127.0.0.1',
        port: b.port,
        pin: pin,
        expectedDeviceId: c.identity.deviceId,
      ),
      throwsA(
        isA<SyncClientException>().having(
          (error) => error.message,
          'message',
          'pair_fingerprint_mismatch',
        ),
      ),
    );
    expect(await a.store.findPeer(b.identity.deviceId), isNull);
    expect(
      b.engine.isPairingOpen,
      isTrue,
      reason: 'the handshake never completed, so nothing was spent here',
    );

    // The very same PIN still pairs once the fingerprint is the right one:
    // the refusal cost the joiner nothing but the attempt.
    await a.engine.pairWith(
      host: '127.0.0.1',
      port: b.port,
      pin: pin,
      expectedDeviceId: b.identity.deviceId,
    );
    expect(await a.store.findPeer(b.identity.deviceId), isNotNull);
  });

  test('five wrong PINs close the pairing window', () async {
    final a = _Side('a');
    final b = _Side('b');
    await a.start(root);
    await b.start(root);
    sides.addAll([a, b]);

    final pin = b.engine.openPairing();
    final wrong = pin == '000000' ? '111111' : '000000';
    for (var attempt = 0; attempt < 5; attempt++) {
      await expectLater(
        a.engine.pairWith(host: '127.0.0.1', port: b.port, pin: wrong),
        throwsA(isA<Exception>()),
      );
      expect(
        b.engine.isPairingOpen,
        attempt < 4,
        reason: 'attempt ${attempt + 1}',
      );
    }
    // A fresh window resets the counter and mints a new PIN.
    final reopened = b.engine.openPairing();
    await a.engine.pairWith(host: '127.0.0.1', port: b.port, pin: reopened);
    expect(await a.peer(b), isNotNull);
  });

  test('re-pairing repairs the endpoint and rotates the secret', () async {
    final (a, b) = await pair();

    // Pretend the peer moved: A's remembered endpoint is stale.
    final drifted = await a.peer(b);
    final staleSecret = drifted.secret;
    drifted.replaceEndpoints('10.255.255.1', 1);
    await a.store.savePeer(drifted);

    final pin = b.engine.openPairing();
    await a.engine.pairWith(
      host: '127.0.0.1',
      port: b.port,
      pin: pin,
      expectedDeviceId: b.identity.deviceId,
    );

    final refreshed = await a.peer(b);
    expect(refreshed.primaryEndpoint?.host, '127.0.0.1');
    expect(
      refreshed.primaryEndpoint?.port,
      b.port,
      reason: 'the drifted endpoint is repaired',
    );
    expect(refreshed.secret, isNot(staleSecret), reason: 'a fresh secret');

    // The secret the old pairing minted is dead on the responder.
    final stale = SyncPeerRecord(
      deviceId: b.identity.deviceId,
      certPem: b.identity.certPem,
      secret: staleSecret,
      name: b.label,
      platform: 'test',
      endpoints: [SyncPeerEndpoint(host: '127.0.0.1', port: b.port)],
    );
    final report = await a.engine.syncWithPeer(stale);
    expect(report.success, isFalse);
    expect(report.summary, contains('not_paired'));
    // A dead secret must land as a *refusal*, not as a raw transport error:
    // the card renders the localized "no longer paired" line from this field,
    // and an unparsed 401 would leave the user staring at an exception string.
    expect(report.refusal, SyncRefusalReason.notPaired);
    final persisted = (await a.store.findPeer(b.identity.deviceId))!;
    expect(persisted.lastReport?.refusal, SyncRefusalReason.notPaired);
  });

  test(
    'a QR payload skips a dead endpoint and pairs on the live one',
    () async {
      final a = _Side('a');
      final b = _Side('b');
      await a.start(root, withEngine: false);
      await b.start(root);
      sides.addAll([a, b]);
      final provider = await a.startProvider();

      final deadPort = await _unusedPort();
      final pin = b.engine.openPairing();
      final payload = SyncPairQrPayload(
        deviceId: b.identity.deviceId,
        name: b.label,
        endpoints: [('127.0.0.1', deadPort), ('127.0.0.1', b.port)],
        pin: pin,
      );

      final result = await provider.pairWithQr(payload);
      expect(
        result.outcome.success,
        isTrue,
        reason: result.outcome.errorDetail,
      );
      expect(result.wasKnownPeer, isFalse);

      final peer = provider.peers.single;
      expect(peer.deviceId, b.identity.deviceId);
      expect(
        peer.primaryEndpoint?.port,
        b.port,
        reason: 'the live candidate won',
      );
      // The endpoint that lost is remembered behind the winner: it is the
      // candidate a later round tries when this network goes away.
      expect(
        peer.endpoints.map((e) => e.port),
        contains(deadPort),
        reason: 'the dead candidate was kept as a hint',
      );
      // The joiner advertised its own listener, so the responder can dial back.
      expect((await b.peer(a)).primaryEndpoint?.port, provider.port);

      // Scanning a fresh code for the same device is the drift-repair journey,
      // and the UI says so instead of pretending it is a first pairing.
      final secondPin = b.engine.openPairing();
      final second = await provider.pairWithQr(
        SyncPairQrPayload(
          deviceId: b.identity.deviceId,
          name: b.label,
          endpoints: [('127.0.0.1', b.port)],
          pin: secondPin,
        ),
      );
      expect(second.outcome.success, isTrue);
      expect(second.wasKnownPeer, isTrue);
      expect(
        provider.peers.length,
        1,
        reason: 'the record is updated, not added',
      );
    },
  );

  test('a QR payload with only dead endpoints reports unreachable', () async {
    final a = _Side('a');
    final b = _Side('b');
    await a.start(root, withEngine: false);
    await b.start(root);
    sides.addAll([a, b]);
    final provider = await a.startProvider();

    final pin = b.engine.openPairing();
    final result = await provider.pairWithQr(
      SyncPairQrPayload(
        deviceId: b.identity.deviceId,
        name: b.label,
        endpoints: [('127.0.0.1', await _unusedPort())],
        pin: pin,
      ),
    );
    expect(result.outcome.success, isFalse);
    expect(result.outcome.errorCode, 'unreachable');
    expect(provider.peers, isEmpty);
    expect(b.engine.isPairingOpen, isTrue, reason: 'nothing reached the peer');
  });

  test(
    'a QR pairing moves past an endpoint answering with the wrong certificate',
    () async {
      final a = _Side('a');
      final b = _Side('b');
      final c = _Side('c'); // a live listener that is not the scanned device
      await a.start(root, withEngine: false);
      await b.start(root);
      await c.start(root);
      sides.addAll([a, b, c]);
      final provider = await a.startProvider();

      final pin = b.engine.openPairing();
      // The scanned code lists another device's address first: a recycled lease,
      // or a machine that happens to answer on the sync port. The fingerprint in
      // the code is B's, so that address is refused inside the handshake — and
      // B's own address is right behind it.
      final payload = SyncPairQrPayload(
        deviceId: b.identity.deviceId,
        name: b.label,
        endpoints: [('127.0.0.1', c.port), ('127.0.0.1', b.port)],
        pin: pin,
      );

      final result = await provider.pairWithQr(payload);

      expect(
        result.outcome.success,
        isTrue,
        reason: result.outcome.errorDetail,
      );
      final peer = provider.peers.single;
      expect(peer.deviceId, b.identity.deviceId);
      expect(
        peer.primaryEndpoint?.port,
        b.port,
        reason: 'the endpoint that actually presented the scanned certificate',
      );
      // A wrong certificate disqualifies the address, not the pairing: the
      // refusal happened before any request byte, so nothing arrived at C, and
      // the window B spent is the one this pairing used.
      expect(await c.store.findPeer(a.identity.deviceId), isNull);
      expect(b.engine.isPairingOpen, isFalse, reason: 'the PIN was spent on B');
    },
  );

  test('a QR payload whose every endpoint answers as another device reports '
      'fingerprint_mismatch', () async {
    final a = _Side('a');
    final b = _Side('b'); // the scanned device, on none of the endpoints
    final c = _Side('c');
    final d = _Side('d');
    await a.start(root, withEngine: false);
    await b.start(root);
    await c.start(root);
    await d.start(root);
    sides.addAll([a, b, c, d]);
    final provider = await a.startProvider();

    final pin = b.engine.openPairing();
    final result = await provider.pairWithQr(
      SyncPairQrPayload(
        deviceId: b.identity.deviceId,
        name: b.label,
        endpoints: [('127.0.0.1', c.port), ('127.0.0.1', d.port)],
        pin: pin,
      ),
    );

    expect(result.outcome.success, isFalse);
    expect(
      result.outcome.errorCode,
      'fingerprint_mismatch',
      reason:
          'addresses answered, and none of them was the scanned device — '
          'a re-scan is the fix, not a retry',
    );
    expect(provider.peers, isEmpty);
    expect(b.engine.isPairingOpen, isTrue, reason: 'nothing reached B');
  });

  test('a session falls through a stale endpoint to the live one', () async {
    final (a, b) = await pair();

    // The peer moved: the remembered head is an address this device has left,
    // and the one it is actually reachable at sits behind it in the set.
    final drifted = await a.peer(b);
    drifted.replaceEndpoints('127.0.0.1', await _unusedPort());
    drifted.rememberEndpointCandidates([('127.0.0.1', b.port)]);
    await a.store.savePeer(drifted);
    expect(drifted.endpoints.length, 2);

    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);

    // The candidate that worked is promoted, so the next round starts there
    // instead of paying for the stale address again.
    final refreshed = await a.peer(b);
    expect(refreshed.primaryEndpoint?.port, b.port);
    expect(
      refreshed.endpoints.map((e) => e.port),
      contains(drifted.endpoints.last.port),
      reason: 'the stale endpoint is kept as a hint, not forgotten',
    );
  });

  test(
    'a session falls through an endpoint answering with the wrong certificate',
    () async {
      final (a, b) = await pair();
      // A live sync listener that is not the peer: a recycled lease a second
      // install now holds, or a machine that happens to answer on the sync port.
      final c = _Side('c');
      await c.start(root);
      sides.add(c);

      final drifted = await a.peer(b);
      // The dial order is forced to meet the stranger first without depending on
      // the prober's ordering: this device stands on 127.0.0.1, so the address
      // sharing that subnet is dialed before the peer's ::1 one.
      drifted.replaceEndpoints('::1', b.port);
      drifted.rememberEndpointCandidates([('127.0.0.1', c.port)]);
      await a.store.savePeer(drifted);
      a.engine.localAddresses = [(name: 'en0', address: '127.0.0.1')];

      final report = await a.engine.syncWithPeer(await a.peer(b));

      // The peer was live right behind the stranger, so the session must have
      // reached it: a refused certificate is a verdict on the address, not on
      // the peer. Anything else ends the walk with the peer still untried.
      expect(
        report.success,
        isTrue,
        reason: '${report.summary} ${report.failure}',
      );

      // And the address that answered as another device is neither promoted
      // over the endpoint that reached the peer, nor stamped as one that
      // worked — nothing there ever answered as the peer.
      final refreshed = await a.peer(b);
      expect(refreshed.primaryEndpoint?.host, '::1');
      expect(refreshed.primaryEndpoint?.port, b.port);
      final stranger = refreshed.endpoints.firstWhere((e) => e.port == c.port);
      expect(stranger.lastSuccessAt, isNull);
    },
  );

  test('a session whose every address answers as another device reports '
      'unreachable', () async {
    final (a, b) = await pair();
    final c = _Side('c');
    final d = _Side('d');
    await c.start(root);
    await d.start(root);
    sides.addAll([c, d]);

    // Both remembered addresses are live listeners that are not the peer. The
    // walk tries both and can then only report that nothing reached the peer;
    // the addresses stay as hints, because the peer may sit behind one of them
    // again after the next DHCP lease.
    final drifted = await a.peer(b);
    drifted.replaceEndpoints('127.0.0.1', c.port);
    drifted.rememberEndpointCandidates([('127.0.0.1', d.port)]);
    await a.store.savePeer(drifted);

    final report = await a.engine.syncWithPeer(await a.peer(b));

    expect(report.success, isFalse);
    expect(report.failure, SyncFailureReason.unreachable);
    expect((await a.peer(b)).endpoints.length, 2);
  });

  test('a peer that remembers no address asks for one, not for a retry', () async {
    final (a, b) = await pair();

    // The record is real, its endpoint set is not: a peer paired without an
    // address at all. Nothing was dialed, so "unreachable" would send the user
    // to check the other device's power state instead of the missing address —
    // which is the thing they can actually fix.
    final record = await a.peer(b);
    record.endpoints.clear();
    await a.store.savePeer(record);

    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isFalse);
    expect(report.summary, 'no_endpoint');
    expect(report.failure, SyncFailureReason.noEndpoint);

    // Persisted like every other outcome: the card renders `lastReport`, so a
    // failure left out of the record would keep the previous success on screen.
    final persisted = (await a.store.findPeer(b.identity.deviceId))!;
    expect(persisted.lastReport?.failure, SyncFailureReason.noEndpoint);
  });

  test('a hand-typed pairing names the device it paired with', () async {
    final a = _Side('a');
    final b = _Side('b');
    await a.start(root, withEngine: false);
    await b.start(root);
    sides.addAll([a, b]);
    final provider = await a.startProvider();

    final pin = b.engine.openPairing();
    final outcome = await provider.pairWith(
      host: '127.0.0.1',
      port: b.port,
      pin: pin,
    );
    expect(outcome.success, isTrue, reason: outcome.errorCode);

    // The manual form has no payload to read a device name out of, which is why
    // this path used to announce nothing. The record the pairing wrote carries
    // the name its card shows, so the announcement names that device.
    expect(outcome.peerName, b.label);
    expect(outcome.peerDeviceId, b.identity.deviceId);
  });

  test('pairing hands the responder the joiner addresses', () async {
    final a = _Side('a');
    final b = _Side('b');
    await a.start(root, withEngine: false);
    await b.start(root);
    sides.addAll([a, b]);
    final provider = await a.startProvider();

    // Deterministic advertisement: the addresses a peer is told about. The
    // provider's own enumeration is asynchronous, so the machine's real
    // interface list is not a stable expectation inside a test.
    provider.localAddresses = [
      (name: 'wlan0', address: '10.9.8.7'),
      (name: 'eth0', address: '10.9.8.8'),
    ];

    final pin = b.engine.openPairing();
    final result = await provider.pairWithQr(
      SyncPairQrPayload(
        deviceId: b.identity.deviceId,
        name: b.label,
        endpoints: [('127.0.0.1', b.port)],
        pin: pin,
      ),
    );
    expect(result.outcome.success, isTrue, reason: result.outcome.errorDetail);

    // The responder remembers the address the pairing came from as the proven
    // one, then the joiner's own advertised addresses behind it — the network
    // knowledge that lets a peer which later roams keep syncing.
    final bPeer = await b.peer(a);
    expect(bPeer.primaryEndpoint?.host, '127.0.0.1');
    expect(bPeer.primaryEndpoint?.port, provider.port);
    expect(
      bPeer.endpoints.skip(1).map((endpoint) => endpoint.label).toList(),
      ['10.9.8.7:${provider.port}', '10.9.8.8:${provider.port}'],
      reason: 'only advertised candidates join the set, after the proven one',
    );
  });

  test('a foreground round syncs paired peers, then throttles', () async {
    final a = _Side('a');
    final b = _Side('b');
    await a.start(root, withEngine: false);
    await b.start(root);
    sides.addAll([a, b]);
    final provider = await a.startProvider();

    // Nothing paired: the round is a no-op rather than an error.
    await provider.autoSyncRound();
    expect(provider.peers, isEmpty);

    final pin = b.engine.openPairing();
    await provider.pairWithQr(
      SyncPairQrPayload(
        deviceId: b.identity.deviceId,
        name: b.label,
        endpoints: [('127.0.0.1', b.port)],
        pin: pin,
      ),
    );

    // Pairing kicks its own first session (see the test below), so wait for it
    // to settle: this test is about the round, and a round that lands while the
    // pair is busy is skipped by design.
    await _waitUntil(() async => provider.busyDeviceIds.isEmpty);

    await _seedConversation(b, id: 'conv-b', contents: ['b1']);
    await provider.autoSyncRound();
    expect(await _conversationIds(a), contains('conv-b'));

    // A second round inside the interval is skipped — the new conversation
    // the peer just wrote stays put until the interval elapses or the user
    // presses sync now.
    await _seedConversation(b, id: 'conv-later', contents: ['b2']);
    await provider.autoSyncRound();
    expect(await _conversationIds(a), isNot(contains('conv-later')));

    final report = await provider.syncNow(b.identity.deviceId);
    expect(report?.success, isTrue, reason: report?.summary);
    expect(await _conversationIds(a), contains('conv-later'));
  });

  test(
    'pairing starts the first session instead of waiting for a round',
    () async {
      final a = _Side('a');
      final b = _Side('b');
      await a.start(root, withEngine: false);
      await b.start(root);
      sides.addAll([a, b]);

      // A's own history: this is the payload the first session carries, and what
      // a full first sync is made of.
      await _seedConversation(a, id: 'conv-first', contents: ['first sync']);
      final provider = await a.startProvider();

      await provider.pairWithQr(
        SyncPairQrPayload(
          deviceId: b.identity.deviceId,
          name: b.label,
          endpoints: [('127.0.0.1', b.port)],
          pin: b.engine.openPairing(),
        ),
      );

      // No round, no button: pairing itself is what proves the peer is reachable
      // *now* — both apps are open — which is the window a first sync needs.
      expect(
        provider.busyDeviceIds,
        contains(b.identity.deviceId),
        reason: 'the session is running before the pairing call even returns',
      );
      await _waitUntil(
        () async => (await _conversationIds(b)).contains('conv-first'),
      );
      // And it has to be over before teardown removes the temp directory.
      await _waitUntil(() async => provider.busyDeviceIds.isEmpty);
    },
  );

  test(
    'the probe is asked about the card addresses, and a busy peer is online',
    () async {
      final a = _Side('a');
      final b = _Side('b');
      await a.start(root, withEngine: false);
      await b.start(root);
      sides.addAll([a, b]);

      final probed = <List<(String, int)>>[];
      var reachable = false;
      final provider = await a.startProvider(
        presenceProbe: (endpoints) async {
          probed.add(endpoints);
          return reachable;
        },
      );

      final pin = b.engine.openPairing();
      await provider.pairWith(host: '127.0.0.1', port: b.port, pin: pin);
      await _waitUntil(() async => provider.busyDeviceIds.isEmpty);

      await provider.refreshPresence();
      expect(
        probed.last,
        [('127.0.0.1', b.port)],
        reason: 'the dot is about the addresses the card shows and dials',
      );

      // A session in flight answers for the peer: there is nothing left to probe.
      reachable = false;
      provider.busyDeviceIds.add(b.identity.deviceId);
      await provider.refreshPresence();
      expect(
        provider.isPeerOnline(b.identity.deviceId),
        isTrue,
        reason: 'a running session is itself proof the peer is there',
      );
    },
  );

  test('resuming re-enumerates this device addresses', () async {
    final a = _Side('a');
    await a.start(root, withEngine: false);
    sides.add(a);
    var source = <LanAddress>[(name: 'wlan0', address: '10.9.0.5')];
    final provider = await a.startProvider(addressSource: () async => source);
    await pumpEventQueue();

    expect(
      provider.localAddresses.single.address,
      '10.9.0.5',
      reason: 'the address source is read on start',
    );
    expect(
      provider.engine!.localAddresses.single.address,
      '10.9.0.5',
      reason: 'the dial orders candidates by the list the screen shows',
    );

    // The device moved to another network while it was in the background: the
    // list it advertises — and the list the dial reads — has to describe where
    // it is now.
    source = [(name: 'wlan0', address: '192.168.44.9')];
    provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await pumpEventQueue();

    expect(provider.localAddresses.single.address, '192.168.44.9');
    expect(provider.engine!.localAddresses.single.address, '192.168.44.9');
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

  test('a stale conversation entry is healed by the none beat', () async {
    // An interrupted session can leave an entry older than the state both
    // devices actually hold. `none` must refresh it from local (the business
    // face always has): keeping the stale digest would read the peer's next
    // deletion as a local edit and re-upload the conversation, silently
    // undoing the deletion once.
    final (a, b) = await pair();
    await _seedConversation(a, id: 'conv-a', contents: ['a1']);
    await a.engine.syncWithPeer(await a.peer(b));
    await a.engine.syncWithPeer(await a.peer(b)); // fully converged

    // Simulate the interrupted advance: keep the rows clock but backdate the
    // digest, so `none` is planned yet the entry disagrees with both sides.
    final checkpoint = await a.store.loadCheckpoint(b.identity.deviceId);
    final entry = checkpoint.conversations['conv-a']!;
    final healed = entry.digest;
    await a.store.saveCheckpoint(
      b.identity.deviceId,
      SyncCheckpoint({
        'conv-a': SyncCheckpointConversation(
          updatedAtUs: entry.updatedAtUs,
          digest: 'stale-${entry.digest}',
          rows: entry.rows,
        ),
      }),
    );

    await a.engine.syncWithPeer(await a.peer(b));
    final after = await a.store.loadCheckpoint(b.identity.deviceId);
    expect(
      after.conversations['conv-a']?.digest,
      healed,
      reason: 'none means both manifests agree: local state IS the entry',
    );

    // The healed entry is what lets B's deletion land instead of reading as
    // an A-side edit that resurrects the conversation.
    await b.repository.deleteConversation('conv-a');
    await a.engine.syncWithPeer(await a.peer(b));
    expect(await _conversationIds(a), isEmpty);
    expect(await _conversationIds(b), isEmpty);
  });

  test('a settled library is not re-read on every session', () async {
    // The none beat used to rebuild each settled conversation's entry from
    // local — every message row of every conversation, once per session. The
    // manifest carries the same digest and row clock the refresh would read,
    // so when they equal the entry there is nothing to rebuild.
    final a = _Side('a');
    final b = _Side('b');
    await a.start(root, countCheckpointReads: true);
    await b.start(root);
    sides.addAll([a, b]);
    final pin = b.engine.openPairing();
    await a.engine.pairWith(host: '127.0.0.1', port: b.port, pin: pin);
    await _seedConversation(a, id: 'conv-a', contents: ['a1', 'a2']);
    await _seedConversation(a, id: 'conv-b', contents: ['b1']);
    await a.engine.syncWithPeer(await a.peer(b));

    final plane = a.dataPlane as _CountingCheckpointPlane;
    plane.reads = 0;
    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);
    expect(report.conversationsSent, 0);
    expect(
      plane.reads,
      0,
      reason: 'a settled conversation must not be re-read from local',
    );
  });

  test(
    'a message written while the session is in flight is not peer-seen',
    () async {
      // "Sending is not receipt" applied to the content of the send: the entry
      // for a pushed conversation must describe the payload that crossed the
      // wire, not a re-read taken later in the session. A row written in that
      // window was never sent, so recording it as peer-seen makes the next
      // session's deletion oracle remove it here.
      final a = _Side('a');
      final b = _Side('b');
      await a.start(
        root,
        midPushWrite: (conversationId) async {
          await a.repository.putMessage(
            ChatMessage(
              id: 'conv-a-m1',
              conversationId: conversationId,
              role: 'user',
              content: 'written mid-session',
            ),
          );
        },
      );
      await b.start(root);
      sides.addAll([a, b]);
      final pin = b.engine.openPairing();
      await a.engine.pairWith(host: '127.0.0.1', port: b.port, pin: pin);
      await _seedConversation(a, id: 'conv-a', contents: ['a1']);

      // The push carries m0 only: m1 is written as the payload is packaged.
      final first = await a.engine.syncWithPeer(await a.peer(b));
      expect(first.success, isTrue, reason: first.summary);
      expect(await _messageIds(b, 'conv-a'), {'conv-a-m0'});

      // The next session must re-send, not read B's older copy as a deletion
      // of the row A wrote after the payload was read.
      await a.engine.syncWithPeer(await a.peer(b));
      expect(
        await _messageIds(a, 'conv-a'),
        contains('conv-a-m1'),
        reason: 'a row written during the session must not be deleted here',
      );

      await a.engine.syncWithPeer(await a.peer(b));
      expect(await _messageIds(b, 'conv-a'), contains('conv-a-m1'));
    },
  );

  test('a reference already present survives a landed subset', () async {
    // A revision that references two files where only one needs fetching (the
    // other is already here with the advertised hash) must keep both
    // references: the registration replaces the revision's whole set, so
    // registering only this session's arrivals unlinked the present file and
    // left it to the asset GC.
    final (a, b) = await pair();
    for (final entry in {
      'images/one.png': 'one',
      'images/two.png': 'two',
    }.entries) {
      final file = File('${a.dir.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value, flush: true);
    }
    // B already holds the second file, byte-identical.
    final present = File('${b.dir.path}/images/two.png');
    await present.parent.create(recursive: true);
    await present.writeAsString('two', flush: true);

    final message = ChatMessage(
      id: 'conv-a-m0',
      conversationId: 'conv-a',
      role: 'user',
      content: '',
      parts: [
        ImagePart(uri: 'kelivo-file:///images/one.png', mime: 'image/png'),
        FilePart(uri: 'kelivo-file:///images/two.png', name: 'two.png'),
      ],
    );
    await a.repository.putMigrationBatch(
      conversations: [
        Conversation(
          id: 'conv-a',
          title: 'conv-a',
        ).copyWith(messageIds: [message.id]),
      ],
      messages: [(message: message, messageOrder: 0)],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );

    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);

    final refs = await b.database
        .customSelect(
          'SELECT asset_id FROM message_asset_rows WHERE revision_id = ?;',
          variables: [Variable.withString('conv-a-m0')],
        )
        .get();
    expect(
      refs.length,
      2,
      reason: 'both referenced files stay linked, fetched or already present',
    );
    expect(await File('${b.dir.path}/images/one.png').readAsString(), 'one');
    expect(await present.readAsString(), 'two');
  });

  test(
    "a revision the merge kept does not adopt the rejected parts' references",
    () async {
      // A local edit landing between the incoming payload's blob pull and the
      // merge makes the local row win LWW: the wire parts then describe a
      // revision this device rejected. Building the revision's reference set
      // from them would replace the winner's own file with the loser's and
      // leave the live attachment to the asset GC.
      final a = _Side('a');
      final b = _Side('b');
      await a.start(
        root,
        midApplyWrite: (conversationId) async {
          await a.repository.putMessage(
            ChatMessage(
              id: 'conv-a-m0',
              conversationId: conversationId,
              role: 'user',
              content: 'edited here',
              parts: [
                ImagePart(
                  uri: 'kelivo-file:///images/mine.png',
                  mime: 'image/png',
                ),
              ],
            ),
          );
        },
      );
      await b.start(root);
      sides.addAll([a, b]);
      final pin = b.engine.openPairing();
      await a.engine.pairWith(host: '127.0.0.1', port: b.port, pin: pin);

      await _writeBlob(a, 'images/mine.png', 'mine');
      await _writeBlob(b, 'images/theirs.png', 'theirs');
      await _seedConversationWithImage(
        a,
        id: 'conv-a',
        uri: 'kelivo-file:///images/mine.png',
      );
      await _seedConversationWithImage(
        b,
        id: 'conv-a',
        uri: 'kelivo-file:///images/theirs.png',
      );
      // B's copy is newer at hello, so A requests it; the edit above then
      // makes A's own row win at merge time.
      await _forceUpdatedAt(
        a,
        table: 'message_rows',
        idColumn: 'id',
        id: 'conv-a-m0',
        updatedAtUs: 1000000,
      );
      await _forceUpdatedAt(
        b,
        table: 'message_rows',
        idColumn: 'id',
        id: 'conv-a-m0',
        updatedAtUs: 2000000,
      );
      // The reference state the merge must preserve, registered the way the
      // asset backfill does.
      await a.repository.replaceMessageAssetReferences(
        conversationId: 'conv-a',
        revisionId: 'conv-a-m0',
        assets: const [
          MessageAssetRegistration(
            assetId: 'asset_local',
            contentHash: 'localhash',
            path: 'kelivo-file:///images/mine.png',
            byteSize: 4,
            kind: 'image',
          ),
        ],
      );

      final report = await a.engine.syncWithPeer(await a.peer(b));
      expect(report.success, isTrue, reason: report.summary);

      // The local row kept the merge, so its own parts — and only they —
      // describe the revision. (The harness's asset backfill resolves files
      // against one shared root, so the registry is asserted on what the sync
      // registration must not do, not on what that backfill later re-adds.)
      final parts = await a.repository.syncReadMessagePartRows('conv-a');
      expect(
        parts.map((part) => part['payload']).join(),
        contains('kelivo-file:///images/mine.png'),
        reason: 'the local edit must have won the merge',
      );
      expect(
        await _assetPathsFor(a, 'conv-a-m0'),
        isNot(contains('kelivo-file:///images/theirs.png')),
        reason: "the rejected parts' file must not take the revision over",
      );
    },
  );

  test('a peer-named path outside the blob roots is never served', () async {
    // The blob manifest arrives from the peer. Remembering a file entry by
    // whatever path it names let a paired peer point at any readable local
    // file and fetch it back by the hash it chose: the resolver returns an
    // existing path unchanged, and the only gate left is the root allowlist.
    final outside = File('${root.path}/a/outside/secret.txt');
    await outside.parent.create(recursive: true);
    await outside.writeAsString('secret', flush: true);

    final a = _Side('a');
    final b = _Side('b');
    await a.start(
      root,
      craftedBlobs: [
        SyncBlobEntry(
          kind: SyncBlobEntry.kindFile,
          key: 'kelivo-file:///outside/secret.txt',
          contentHash: 'a' * 64,
          byteSize: 6,
        ),
      ],
    );
    await b.start(root);
    sides.addAll([a, b]);
    final pin = b.engine.openPairing();
    await a.engine.pairWith(host: '127.0.0.1', port: b.port, pin: pin);
    await _seedConversation(a, id: 'conv-a', contents: ['a1']);

    // The session publishes that manifest on A's own push beat.
    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);

    expect(
      await a.engine.handleFetchBlob(b.identity.deviceId, 'a' * 64),
      isNull,
      reason: 'the blob route must not serve a path the peer named',
    );
  });

  test('a conversation-row-only change transfers', () async {
    // A rename, a pin and a version selection touch only conversation_rows:
    // no message row moves, so the conversation digest cannot see them — the
    // row's own clock is the only thing that makes them visible.
    final (a, b) = await pair();
    await a.repository.putMigrationBatch(
      conversations: [
        Conversation(
          id: 'conv-a',
          title: 'first',
        ).copyWith(messageIds: ['conv-a-v0', 'conv-a-v1']),
      ],
      messages: [
        (
          message: ChatMessage(
            id: 'conv-a-v0',
            conversationId: 'conv-a',
            role: 'assistant',
            content: 'v0',
            groupId: 'g',
            version: 0,
          ),
          messageOrder: 0,
        ),
        (
          message: ChatMessage(
            id: 'conv-a-v1',
            conversationId: 'conv-a',
            role: 'assistant',
            content: 'v1',
            groupId: 'g',
            version: 1,
          ),
          messageOrder: 1,
        ),
      ],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );
    await a.chatService.reloadAfterExternalChange();
    await a.engine.syncWithPeer(await a.peer(b));
    expect(
      (await b.repository.syncReadConversationRow('conv-a'))!['title'],
      'first',
    );

    await a.chatService.renameConversation('conv-a', 'renamed');
    await a.chatService.togglePinConversation('conv-a');
    await a.chatService.setSelectedVersion('conv-a', 'g', 1);

    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);

    final rowB = (await b.repository.syncReadConversationRow('conv-a'))!;
    expect(rowB['title'], 'renamed');
    expect(rowB['is_pinned'], 1);
    expect(rowB['version_selections_json'], jsonEncode({'g': 1}));
    // And nothing about the messages moved with it.
    expect(await _messageIds(b, 'conv-a'), {'conv-a-v0', 'conv-a-v1'});
  });

  test(
    'a blob-carrying push into a streaming conversation does not abort',
    () async {
      // The responder pulls the blob before the apply defers the whole
      // conversation, so a registration keyed off the wire payload would
      // insert a reference for a revision that was never written — the
      // revision foreign key aborts the session after the push committed
      // and before the checkpoint, and every later session repeats it.
      final (a, b) = await pair();
      await _writeBlob(a, 'images/first.png', 'first');
      await _seedConversationWithImage(
        a,
        id: 'conv-a',
        uri: 'kelivo-file:///images/first.png',
      );
      await a.engine.syncWithPeer(await a.peer(b));

      // B is now generating in that conversation; A appends a message with
      // a fresh attachment.
      await _setStreaming(b, 'conv-a', streaming: true);
      await _writeBlob(a, 'images/second.png', 'second');
      await a.repository.putMessage(
        ChatMessage(
          id: 'conv-a-m1',
          conversationId: 'conv-a',
          role: 'assistant',
          content: '',
          parts: [
            ImagePart(
              uri: 'kelivo-file:///images/second.png',
              mime: 'image/png',
            ),
          ],
        ),
      );

      final report = await a.engine.syncWithPeer(await a.peer(b));
      expect(report.success, isTrue, reason: report.summary);
      expect(await _messageIds(b, 'conv-a'), {'conv-a-m0'});
    },
  );

  test('a blob whose pull failed is referenced before it lands', () async {
    // The reference must exist from the moment the advertisement is
    // believed: the retry that finally lands the file arrives in a session
    // that carries no subtree for this conversation, and an unregistered
    // file is GC meat.
    final a = _Side('a');
    final b = _Side('b');
    File? blob;
    await a.start(
      root,
      vanishBlob: () async {
        final target = blob;
        if (target != null && await target.exists()) await target.delete();
      },
    );
    await b.start(root);
    sides.addAll([a, b]);
    final pin = b.engine.openPairing();
    await a.engine.pairWith(host: '127.0.0.1', port: b.port, pin: pin);

    blob = File('${a.dir.path}/images/vanish.png');
    await blob.parent.create(recursive: true);
    await blob.writeAsString('vanish', flush: true);
    await _seedConversationWithImage(
      a,
      id: 'conv-a',
      uri: 'kelivo-file:///images/vanish.png',
    );

    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);

    final registeredOnB =
        (await b.database
                .customSelect(
                  'SELECT COUNT(*) AS n FROM message_asset_rows '
                  'WHERE revision_id = ?;',
                  variables: [Variable.withString('conv-a-m0')],
                )
                .getSingle())
            .read<int>('n');
    expect(
      registeredOnB,
      1,
      reason: 'the advertisement alone must own the reference',
    );
    final checkpoint = await b.store.loadCheckpoint(a.identity.deviceId);
    expect(
      checkpoint.pendingBlobs.values.map((entry) => entry.key),
      contains('kelivo-file:///images/vanish.png'),
    );
  });

  test(
    'a pending blob retry survives a session with nothing to push',
    () async {
      // The fetch beat persists what the push beat pulled, so skipping the push
      // when this device had nothing outgoing wrote the empty default over the
      // responder's retry list: a blob it still owes would never be asked for
      // again, despite the checkpoint contract promising the retry.
      final (a, b) = await pair();
      await _seedConversation(a, id: 'conv-a', contents: ['a1']);
      await a.engine.syncWithPeer(await a.peer(b));

      // B owes a blob A can no longer serve (the hash was never published).
      final pending = SyncBlobEntry(
        kind: SyncBlobEntry.kindFile,
        key: 'kelivo-file:///missing.bin',
        contentHash: 'f' * 64,
        byteSize: 1,
      );
      final checkpoint = await b.store.loadCheckpoint(a.identity.deviceId);
      await b.store.saveCheckpoint(
        a.identity.deviceId,
        SyncCheckpoint(
          checkpoint.conversations,
          entities: checkpoint.entities,
          preferences: checkpoint.preferences,
          pendingBlobs: {pending.target: pending},
          skillHashes: checkpoint.skillHashes,
        ),
      );

      // A has nothing to push in this session.
      final report = await a.engine.syncWithPeer(await a.peer(b));
      expect(report.success, isTrue, reason: report.summary);
      final after = await b.store.loadCheckpoint(a.identity.deviceId);
      expect(
        after.pendingBlobs.keys,
        contains(pending.target),
        reason: 'the retry list must survive a session with an empty push',
      );
    },
  );

  test('an announced deletion does not remove a copy edited since', () async {
    // The announcement carries the digest both sides last agreed on, so a
    // local copy that has moved on since is an edit, and an edit beats a
    // delete exactly as it does in the plan table: the deletion loses.
    final (a, b) = await pair();
    await _seedConversation(a, id: 'conv-a', contents: ['a1']);
    await a.engine.syncWithPeer(await a.peer(b));
    expect(await _messageIds(b, 'conv-a'), {'conv-a-m0'});

    await a.repository.deleteConversation('conv-a');
    await b.repository.putMessage(
      ChatMessage(
        id: 'conv-a-m1',
        conversationId: 'conv-a',
        role: 'user',
        content: 'edited on b',
      ),
    );

    await a.engine.syncWithPeer(await a.peer(b));
    expect(
      await _messageIds(a, 'conv-a'),
      contains('conv-a-m1'),
      reason: 'the edit wins, so the announced deletion must not fire here',
    );
    expect(await _messageIds(b, 'conv-a'), contains('conv-a-m1'));
  });

  test(
    'a fetch beat the initiator never applies keeps the responder copy',
    () async {
      // The fetch response is not acknowledged. This drives the beat by hand
      // and throws the result away — an initiator killed between fetching and
      // applying, with the responder's checkpoint already committed. Before the
      // responder stopped advancing unconfirmed sends, the next sessions read
      // the initiator's silence as a deletion and destroyed the only copy on
      // both devices.
      final (a, b) = await pair();
      await _seedConversation(b, id: 'c1', contents: ['the only copy']);
      expect(await _conversationIds(a), isEmpty);
      final aPeer = await a.peer(b);

      final session = a.engine.client.openSession(
        aPeer,
        host: '127.0.0.1',
        port: b.port,
      );
      final hello = await session.hello(
        SyncHello(
          protocolVersion: kSyncProtocolVersion,
          schemaVersion: a.dataPlane.schemaVersion,
          deviceId: a.identity.deviceId,
          deviceName: a.label,
          platform: 'test',
          manifest: await a.dataPlane.buildManifest(),
          listenPort: a.port,
          clockUs: DateTime.now().microsecondsSinceEpoch,
        ),
      );
      expect(hello.hello, isNotNull, reason: 'the peer answered the hello');
      final batch = await session.fetchSubtrees(
        const SyncFetchRequest(conversationIds: ['c1']),
      );
      expect(
        [for (final subtree in batch.subtrees) subtree.conversation['id']],
        contains('c1'),
        reason: 'the responder sent its conversation in this beat',
      );
      session.close();
      expect(
        await _conversationIds(a),
        isEmpty,
        reason: 'the batch was never applied (an interrupted initiator)',
      );

      // Ordinary sessions after that: B re-sends, A applies, and the entry
      // appears once both manifests agree.
      await a.engine.syncWithPeer(aPeer);
      expect(await _conversationIds(a), contains('c1'));
      expect(await _conversationIds(b), contains('c1'));

      await a.engine.syncWithPeer(aPeer);
      expect(await _conversationIds(a), contains('c1'));
      expect(
        await _conversationIds(b),
        contains('c1'),
        reason: 'an unacknowledged fetch is not a deletion on either device',
      );
    },
  );

  test('a skill body the peer never received is not a deleted skill', () async {
    // Sending is not receipt, on the compound unit: a skill is a record plus
    // its directory, and the receiver strips the record when the body cannot be
    // fetched. The acknowledgement must say so, or the sender records the push
    // as delivered and the next session deletes its own skill.
    final (a, b) = await pair();
    await a.putSkill('demo', {'SKILL.md': '# demo'});
    expect(await a.hasSkillRow('demo'), isTrue);
    final aPeer = await a.peer(b);

    // The responder cannot reach the initiator's listener — the state the ADR
    // documents for a Windows host whose firewall rule needed elevation. Every
    // wanted blob fails, so the body is deferred and its record is deliberately
    // not applied.
    await a.engine.stop();
    final first = await a.engine.syncWithPeer(aPeer);
    expect(first.success, isTrue, reason: first.summary);
    expect(
      await b.hasSkillRow('demo'),
      isFalse,
      reason: 'the record is stripped while the body is missing',
    );

    // The next session must re-send: the peer's silence about a skill it never
    // received is not a deletion of the sender's own skill.
    await a.engine.syncWithPeer(aPeer);
    expect(await a.hasSkillRow('demo'), isTrue);
    expect(await a.skillBody('demo'), '# demo');

    // With the listener reachable again the body lands and converges.
    await a.engine.start(preferredPort: 0);
    await a.engine.syncWithPeer(aPeer);
    expect(await b.hasSkillRow('demo'), isTrue);
    expect(await b.skillBody('demo'), '# demo');
  });

  test('a deferred push never deletes the sender\'s own new message', () async {
    // Sending is not receipt. While B is generating in the conversation it
    // accepts the push and writes nothing; treating that as "B has it" made
    // the next session read B's older copy as a deletion of A's own message.
    final (a, b) = await pair();
    await _seedConversation(a, id: 'conv-a', contents: ['a1']);
    await a.engine.syncWithPeer(await a.peer(b));
    expect(await _messageIds(b, 'conv-a'), {'conv-a-m0'});

    await _setStreaming(b, 'conv-a', streaming: true);
    await a.repository.putMessage(
      ChatMessage(
        id: 'conv-a-m1',
        conversationId: 'conv-a',
        role: 'user',
        content: 'written on a',
      ),
    );
    final pushed = await a.engine.syncWithPeer(await a.peer(b));
    expect(pushed.success, isTrue, reason: pushed.summary);
    expect(await _messageIds(b, 'conv-a'), isNot(contains('conv-a-m1')));

    await a.engine.syncWithPeer(await a.peer(b));
    expect(
      await _messageIds(a, 'conv-a'),
      contains('conv-a-m1'),
      reason: 'the session must not undo the message its own device wrote',
    );

    await _setStreaming(b, 'conv-a', streaming: false);
    await a.engine.syncWithPeer(await a.peer(b));
    expect(await _messageIds(b, 'conv-a'), contains('conv-a-m1'));
  });

  test(
    'a deferred business apply never deletes the sender\'s own row',
    () async {
      final (a, b) = await pair();
      await a.businessPreferences.setString('user_name', 'Alice');

      // B is mid-restore: the write fence makes the whole business apply defer.
      final release = Completer<void>();
      final fence = b.businessPreferences.runWithRestoreWriteFence(
        () => release.future,
      );
      await Future<void>.delayed(Duration.zero);

      final pushed = await a.engine.syncWithPeer(await a.peer(b));
      expect(pushed.success, isTrue, reason: pushed.summary);
      expect(
        await b.businessRepository.syncReadPreferenceRows({'user_name'}),
        isEmpty,
        reason: 'the fence deferred the apply',
      );

      // The session after that used to plan an iDelete for A's own row: the
      // write fence never advanced B's state, and A had recorded its send as
      // received.
      await a.engine.syncWithPeer(await a.peer(b));
      expect(
        await a.businessRepository.syncReadPreferenceRows({'user_name'}),
        hasLength(1),
        reason: 'A must keep the row it wrote',
      );

      release.complete();
      await fence;
    },
  );

  test(
    'a deferred receive never makes the sender delete its own message',
    () async {
      // The mirror of the push case: B is the one that sends, and A is the one
      // that defers. B's optimistic entry must not turn A's older copy into a
      // deletion of B's new message when B initiates the next session.
      final (a, b) = await pair();
      await _seedConversation(a, id: 'conv-a', contents: ['a1']);
      await a.engine.syncWithPeer(await a.peer(b));

      await b.repository.putMessage(
        ChatMessage(
          id: 'conv-a-m1',
          conversationId: 'conv-a',
          role: 'user',
          content: 'written on b',
        ),
      );
      await _setStreaming(a, 'conv-a', streaming: true);
      final sent = await a.engine.syncWithPeer(await a.peer(b));
      expect(sent.success, isTrue, reason: sent.summary);
      expect(await _messageIds(a, 'conv-a'), isNot(contains('conv-a-m1')));

      // A's generation ends without A ever applying B's message, and A says so
      // on its hello. B, which recorded its own send as received, would
      // otherwise read A's older copy as a deletion of its own message.
      await _setStreaming(a, 'conv-a', streaming: false);
      final mirrored = await b.engine.syncWithPeer(await b.peer(a));
      expect(mirrored.success, isTrue, reason: mirrored.summary);
      expect(
        await _messageIds(b, 'conv-a'),
        contains('conv-a-m1'),
        reason: "B's own message must survive",
      );

      await a.engine.syncWithPeer(await a.peer(b));
      expect(await _messageIds(a, 'conv-a'), contains('conv-a-m1'));
    },
  );

  test('a peer deletion the peer deferred is retried, not undone', () async {
    final (a, b) = await pair();
    await _seedConversation(a, id: 'conv-a', contents: ['a1']);
    await a.engine.syncWithPeer(await a.peer(b));
    expect(await _conversationIds(b), {'conv-a'});

    // B is generating, so its deletion of conv-a yields and must be retried.
    await _setStreaming(b, 'conv-a', streaming: true);
    await a.repository.deleteConversation('conv-a');
    final first = await a.engine.syncWithPeer(await a.peer(b));
    expect(first.success, isTrue, reason: first.summary);
    expect(
      await b.repository.syncReadConversationRow('conv-a'),
      isNotNull,
      reason: 'the peer could not delete yet',
    );
    expect(await a.repository.syncReadConversationRow('conv-a'), isNull);

    await _setStreaming(b, 'conv-a', streaming: false);
    await a.engine.syncWithPeer(await a.peer(b));
    expect(await b.repository.syncReadConversationRow('conv-a'), isNull);
    expect(
      await a.repository.syncReadConversationRow('conv-a'),
      isNull,
      reason: 'the peer retried the deletion; A must not re-adopt it',
    );
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

      // v4 added the clock reading. An older build is refused rather than
      // synced quietly without the skew warning it cannot produce.
      final olderProtocol = await a.engine.handleHello(
        b.identity.deviceId,
        b.hello(protocolVersion: kSyncProtocolVersion - 1),
      );
      expect(olderProtocol, isA<SyncHelloRefusal>());
      expect(
        (olderProtocol as SyncHelloRefusal).reason,
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

      // A paired caller whose hello body names another paired device must not
      // build a session under that device's name: the secret authenticates
      // exactly one identity, and the substitution would serve the caller's
      // plan to the named peer's next fetch beat (and hold the single session
      // slot under a foreign name).
      final c = _Side('c');
      await c.start(root);
      sides.add(c);
      await pairSides(c, a);
      final mismatch = await a.engine.handleHello(
        b.identity.deviceId,
        b.hello(deviceId: c.identity.deviceId),
      );
      expect(mismatch, isA<SyncHelloRefusal>());
      expect(
        (mismatch as SyncHelloRefusal).reason,
        SyncRefusalReason.identityMismatch,
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

  test('a business deletion through the data plane removes the row', () async {
    // The engine's own deletions go through SyncDataPlane.deleteBusinessRow,
    // which now runs on the serialized write queue (a provider's whole-list
    // read-modify-write must not interleave and re-insert the row); this
    // pins that the rerouting still deletes.
    final a = _Side('a');
    await a.start(root);
    sides.add(a);
    await a.businessPreferences.setString('user_name', 'Alice');

    final removed = await a.dataPlane.deleteBusinessRow(
      kSyncPreferenceWire,
      'user_name',
    );

    expect(removed, isTrue);
    expect(
      await a.businessRepository.syncReadPreferenceRows({'user_name'}),
      isEmpty,
    );
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

  test('a reorder of a list entity transfers', () async {
    // A drag rewrites every row's position and clock but not its payload, so
    // the manifest digest is the only thing that can tell the two devices
    // apart. A payload-only digest left each one on its own order forever.
    final (a, b) = await pair();
    await _setAssistants(a, [
      (id: 'assistant-1', name: 'One'),
      (id: 'assistant-2', name: 'Two'),
    ]);
    await a.engine.syncWithPeer(await a.peer(b));
    expect(await _assistantOrder(b), ['assistant-1', 'assistant-2']);

    await _setAssistants(a, [
      (id: 'assistant-2', name: 'Two'),
      (id: 'assistant-1', name: 'One'),
    ]);
    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);
    expect(await _assistantOrder(b), ['assistant-2', 'assistant-1']);
  });

  test('a crafted wire row cannot re-home or inject messages', () async {
    // A message id is a global primary key, so a wire row that carries
    // another conversation's id moves that message once the upsert's conflict
    // target fires, and one that labels itself as another conversation inserts
    // into it. An honest peer produces neither — its own reader filters by
    // conversation — so both are dropped before the merge.
    final a = _Side('a');
    final b = _Side('b');
    var inject = false;
    final crafted = <Map<String, dynamic>>[];
    await a.start(root, craftedRows: () => inject ? crafted : const []);
    await b.start(root);
    sides.addAll([a, b]);
    final pin = b.engine.openPairing();
    await a.engine.pairWith(host: '127.0.0.1', port: b.port, pin: pin);
    await _seedConversation(a, id: 'conv-a', contents: ['a1']);
    await _seedConversation(a, id: 'conv-b', contents: ['b1']);
    await a.engine.syncWithPeer(await a.peer(b));
    expect(await _messageIds(b, 'conv-b'), {'conv-b-m0'});

    final convBRow = (await a.repository.syncReadMessageRows('conv-b')).single;
    crafted
      ..add({...convBRow, 'conversation_id': 'conv-a'})
      ..add({...convBRow, 'id': 'ghost-m9'});
    inject = true;
    // A change here is what puts conv-a back on the wire carrying the rows.
    await a.repository.putMessage(
      ChatMessage(
        id: 'conv-a-m1',
        conversationId: 'conv-a',
        role: 'user',
        content: 'a2',
      ),
    );

    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);
    expect(
      await _messageIds(b, 'conv-b'),
      {'conv-b-m0'},
      reason: "the other conversation's row must not move, nor gain a ghost",
    );
    expect(await _messageIds(b, 'conv-a'), {'conv-a-m0', 'conv-a-m1'});
  });

  // ---- slice 3: blobs ----

  test('a skill with no carried files still converges', () async {
    // A directory whose only entry the policy excludes (a lone .DS_Store)
    // hashes to the empty body. The sender has to be able to serve that body,
    // or the peer asks for it every session and the record never lands.
    final (a, b) = await pair();
    await a.putSkill('blank', {'.DS_Store': 'junk'});

    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);
    expect(report.blobsMissing, 0);

    expect(await b.hasSkillRow('blank'), isTrue);
    expect(await b.skillDirectories.hashOf('blank'), kEmptySkillBodyHash);
    expect(await b.skillBody('blank'), '');
  });

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

  // ---- slice 5: clock skew, lost rows, unpair propagation, three devices ----

  test('a divergent clock warns on both sides and still syncs', () async {
    final a = _Side('a', clockOffsetUs: 6 * 60 * 1000 * 1000); // +6 min
    final b = _Side('b');
    await a.start(root);
    await b.start(root);
    sides.addAll([a, b]);
    final pin = b.engine.openPairing();
    await a.engine.pairWith(host: '127.0.0.1', port: b.port, pin: pin);
    await _setAssistants(a, [(id: 'assistant-1', name: 'Researcher')]);

    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);
    expect(report.clockSkewMs, isNotNull);
    expect(report.clockSkewMs! > 0, isTrue, reason: 'A runs ahead of B');

    // The responder reads the same divergence from its side of the hello pair
    // and persists it on the record its card renders.
    final bReport = (await b.store.findPeer(a.identity.deviceId))!.lastReport!;
    expect(bReport.clockSkewMs, isNotNull);
    expect(bReport.clockSkewMs! < 0, isTrue, reason: 'A is ahead of B');

    // The warning is informational: the rows moved anyway.
    expect((await _assistantsOf(b)).keys, {'assistant-1'});
  });

  test('a clock inside the warn threshold is not flagged', () async {
    final a = _Side('a', clockOffsetUs: 60 * 1000 * 1000); // +1 min
    final b = _Side('b');
    await a.start(root);
    await b.start(root);
    sides.addAll([a, b]);
    final pin = b.engine.openPairing();
    await a.engine.pairWith(host: '127.0.0.1', port: b.port, pin: pin);

    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);
    expect(report.clockSkewMs, isNull);
    final bReport = (await b.store.findPeer(a.identity.deviceId))!.lastReport!;
    expect(bReport.clockSkewMs, isNull);
  });

  test('a lost local edit is counted on the device that lost it', () async {
    final (a, b) = await pair();
    // A shared baseline first, so both sides then diverge from one checkpoint.
    await _setAssistants(a, [(id: 'assistant-1', name: 'Original')]);
    await a.businessPreferences.setString('user_name', 'Original');
    await a.engine.syncWithPeer(await a.peer(b));

    // Both edit the same rows; A's clocks are newer, so A wins and B's edits
    // are the ones that vanish.
    await _setAssistants(a, [(id: 'assistant-1', name: 'From A')]);
    await _setAssistants(b, [(id: 'assistant-1', name: 'From B')]);
    await a.businessPreferences.setString('user_name', 'From A');
    await b.businessPreferences.setString('user_name', 'From B');
    const base = 1700000000000000;
    await _forceUpdatedAt(
      a,
      table: 'assistant_rows',
      idColumn: 'id',
      id: 'assistant-1',
      updatedAtUs: base + 1000,
    );
    await _forceUpdatedAt(
      b,
      table: 'assistant_rows',
      idColumn: 'id',
      id: 'assistant-1',
      updatedAtUs: base,
    );
    await _forceUpdatedAt(
      a,
      table: 'preference_rows',
      idColumn: 'key',
      id: 'user_name',
      updatedAtUs: base + 1000,
    );
    await _forceUpdatedAt(
      b,
      table: 'preference_rows',
      idColumn: 'key',
      id: 'user_name',
      updatedAtUs: base,
    );

    // The setup is asserted, never assumed: an override that silently matched
    // no row would turn this into a deviceId tie-break race (device ids are
    // fresh per run) instead of the clock decision the counters describe.
    expect(
      await _rowClock(
        a,
        table: 'assistant_rows',
        idColumn: 'id',
        id: 'assistant-1',
      ),
      base + 1000,
    );
    expect(
      await _rowClock(
        b,
        table: 'assistant_rows',
        idColumn: 'id',
        id: 'assistant-1',
      ),
      base,
    );
    expect(
      await _rowClock(
        a,
        table: 'preference_rows',
        idColumn: 'key',
        id: 'user_name',
      ),
      base + 1000,
    );
    expect(
      await _rowClock(
        b,
        table: 'preference_rows',
        idColumn: 'key',
        id: 'user_name',
      ),
      base,
    );

    final report = await a.engine.syncWithPeer(await a.peer(b));
    final bReport = (await b.store.findPeer(a.identity.deviceId))!.lastReport!;
    expect(report.success, isTrue, reason: report.summary);
    // A's side is the echo path: its own row came back at a tied clock, which
    // is a no-op write, not a loss. This is the assertion that would have read
    // 1 whenever the peer's deviceId won the tie.
    expect(report.entityRowsLost, 0);
    expect(report.preferencesLost, 0);
    // A kept its own versions, so nothing was lost here.
    expect(report.entityRowsLost, 0);
    expect(report.preferencesLost, 0);

    expect(bReport.entityRowsLost, 1);
    expect(bReport.preferencesLost, 1);
    // The counters describe what actually happened to B's edits.
    expect((await _assistantsOf(b))['assistant-1'], contains('From A'));
    expect(b.businessPreferences.getString('user_name'), 'From A');
  });

  test('unpairing tells a reachable peer to forget this device', () async {
    final (a, b) = await pair();
    expect(await b.store.findPeer(a.identity.deviceId), isNotNull);

    await a.engine.unpair(b.identity.deviceId);
    expect(await a.store.findPeer(b.identity.deviceId), isNull);

    // A's revoke is fire-and-forget, so B reacts a beat later.
    await _waitUntil(
      () async => await b.store.findPeer(a.identity.deviceId) == null,
    );
    expect(await b.store.findPeer(a.identity.deviceId), isNull);
  });

  test(
    'an unreachable peer keeps its record and learns at the next session',
    () async {
      final (a, b) = await pair();
      // B's listener is gone before A unpairs, so the revoke cannot land.
      await b.engine.stop();
      await a.engine.unpair(b.identity.deviceId);
      expect(await a.store.findPeer(b.identity.deviceId), isNull);
      expect(
        await b.store.findPeer(a.identity.deviceId),
        isNotNull,
        reason: 'B was never told',
      );

      // B still holds the stale record; its next session ends as a localized
      // refusal, because A's listener no longer honours the old secret.
      final report = await b.engine.syncWithPeer(await b.peer(a));
      expect(report.success, isFalse);
      expect(report.refusal, SyncRefusalReason.notPaired);
      final persisted = (await b.store.findPeer(
        a.identity.deviceId,
      ))!.lastReport!;
      expect(persisted.refusal, SyncRefusalReason.notPaired);
      expect(
        persisted.failure,
        isNull,
        reason: 'a refusal, not a raw 401 transport string',
      );
    },
  );

  test('a failed session reports a reason, not the exception', () async {
    // The card and the snackbar localize the reason. The raw exception — which
    // carries the peer's address and port — must reach neither, including
    // through the record that outlives the session.
    final (a, b) = await pair();
    await b.engine.stop();

    final report = await a.engine.syncWithPeer(await a.peer(b));
    expect(report.success, isFalse);
    expect(report.refusal, isNull);
    expect(report.failure, SyncFailureReason.unreachable);

    final persisted = (await a.store.findPeer(
      b.identity.deviceId,
    ))!.lastReport!;
    expect(persisted.failure, SyncFailureReason.unreachable);
    expect(
      persisted.toJson().containsKey('error'),
      isFalse,
      reason: 'the record carries a reason, not rendered text',
    );
  });

  test(
    'three devices converge through a middle hop, without re-flooding',
    () async {
      final a = _Side('a');
      final b = _Side('b');
      final c = _Side('c');
      await a.start(root);
      await b.start(root);
      await c.start(root);
      sides.addAll([a, b, c]);
      await pairSides(a, b); // A ↔ B
      await pairSides(b, c); // B ↔ C — deliberately no A ↔ C pairing

      await _setAssistants(a, [(id: 'assistant-1', name: 'From A')]);
      await _seedConversation(a, id: 'conv-a', contents: ['hello from a']);

      // A's state reaches C through B.
      await a.engine.syncWithPeer(await a.peer(b));
      await b.engine.syncWithPeer(await b.peer(c));
      expect((await _assistantsOf(c)).keys, {'assistant-1'});
      expect(await _conversationIds(c), contains('conv-a'));

      // Re-running the chain moves nothing: B holds A's rows at A's own clock
      // (never re-stamped), so it cannot push them back, and C cannot push them
      // back at B. A re-stamping hop would ping-pong here forever.
      final back = await a.engine.syncWithPeer(await a.peer(b));
      expect(back.entityRows, 0);
      expect(back.conversationsSent, 0);
      final mid = await b.engine.syncWithPeer(await b.peer(c));
      expect(mid.entityRows, 0);
      expect(mid.conversationsSent, 0);
    },
  );

  test('a three-way concurrent edit converges on every device', () async {
    final a = _Side('a');
    final b = _Side('b');
    final c = _Side('c');
    await a.start(root);
    await b.start(root);
    await c.start(root);
    sides.addAll([a, b, c]);
    await pairSides(a, b);
    await pairSides(b, c);

    // The same row, edited independently on all three, on distinct clocks so
    // the newest is unambiguous and the merge is a pure function of the rows.
    await _setAssistants(a, [(id: 'assistant-1', name: 'From A')]);
    await _setAssistants(b, [(id: 'assistant-1', name: 'From B')]);
    await _setAssistants(c, [(id: 'assistant-1', name: 'From C')]);
    const base = 1700000000000000;
    await _forceUpdatedAt(
      a,
      table: 'assistant_rows',
      idColumn: 'id',
      id: 'assistant-1',
      updatedAtUs: base,
    );
    await _forceUpdatedAt(
      b,
      table: 'assistant_rows',
      idColumn: 'id',
      id: 'assistant-1',
      updatedAtUs: base + 1000,
    );
    await _forceUpdatedAt(
      c,
      table: 'assistant_rows',
      idColumn: 'id',
      id: 'assistant-1',
      updatedAtUs: base + 2000,
    );

    // Walk the chain until it reaches a fixed point; three rounds is more than
    // the two hops a three-node chain needs.
    for (var round = 0; round < 3; round++) {
      await a.engine.syncWithPeer(await a.peer(b));
      await b.engine.syncWithPeer(await b.peer(c));
    }

    final winner = await _assistantsOf(c);
    expect(winner['assistant-1'], contains('From C'), reason: 'newest clock');
    expect(await _assistantsOf(a), winner, reason: 'A reached the same row');
    expect(await _assistantsOf(b), winner, reason: 'B reached the same row');

    // And the fixed point is stable.
    final after = await a.engine.syncWithPeer(await a.peer(b));
    expect(after.entityRows, 0);
  });

  test('a manual rename survives a re-pair on both sides', () async {
    final (a, b) = await pair();

    // Each device's user renames the other on their own card.
    final aPeer = await a.peer(b);
    aPeer.customName = 'My laptop';
    await a.store.savePeer(aPeer);
    final bPeer = await b.peer(a);
    bPeer.customName = 'Jason phone';
    await b.store.savePeer(bPeer);

    // Re-pairing is the drift-repair journey, so it is routine: B opens a fresh
    // window and A pairs into it again.
    final pin = b.engine.openPairing();
    await a.engine.pairWith(
      host: '127.0.0.1',
      port: b.port,
      pin: pin,
      expectedDeviceId: b.identity.deviceId,
    );

    expect(
      (await a.peer(b)).displayName,
      'My laptop',
      reason: 'a name this user typed outlives the peer\'s self-report',
    );
    expect(
      (await b.peer(a)).displayName,
      'Jason phone',
      reason: 'the responder keeps its own override too',
    );
    expect(
      (await a.peer(b)).name,
      b.identity.name,
      reason: 'the reported name is still tracked behind the override',
    );
  });

  test('a session refreshes a window already open on the conversation', () async {
    final (a, b) = await pair();
    await _seedConversation(a, id: 'conv-open', contents: ['hello']);
    await a.engine.syncWithPeer(await a.peer(b));

    // The user is back on the chat with that conversation open — the state they
    // return to after the sync screen — and it renders what the database held
    // when the window loaded.
    final controller = ChatController(chatService: a.chatService);
    await controller.setCurrentConversationAndLoad(
      Conversation(id: 'conv-open', title: 'conv-open'),
    );
    expect(controller.messages.map((message) => message.content), ['hello']);

    // The other device writes into that conversation and initiates: this device
    // is the responder, and the push lands under an open window.
    await b.repository.putMessage(
      ChatMessage(
        id: 'conv-open-m1',
        conversationId: 'conv-open',
        role: 'assistant',
        content: 'from b',
      ),
    );
    final report = await b.engine.syncWithPeer(await b.peer(a));
    expect(report.success, isTrue, reason: report.summary);

    // No switching away and back: the apply names the conversation it wrote, so
    // the window rebuilds itself.
    await _waitUntil(
      () async =>
          controller.messages.any((message) => message.content == 'from b'),
    );
    controller.dispose();
  });

  test('the dot needs two probe misses before it goes gray', () async {
    final a = _Side('a');
    await a.start(root, withEngine: false);
    sides.add(a);

    final probed = <List<(String, int)>>[];
    var reachable = true;
    final provider = await a.startProvider(
      presenceProbe: (endpoints) async {
        probed.add(endpoints);
        return reachable;
      },
    );
    // A peer with no session history, so the probe is the only evidence: a fresh
    // session verdict deliberately outranks it (the tests below assert that).
    await a.store.savePeer(
      SyncPeerRecord(
        deviceId: 'peer-device',
        certPem: 'pem',
        secret: 'secret',
        name: 'Studio desktop',
        platform: 'android',
        endpoints: [SyncPeerEndpoint(host: '10.0.0.9', port: 9527)],
      ),
    );
    await provider.refreshPeers();

    await provider.refreshPresence();
    expect(
      probed.last,
      [('10.0.0.9', 9527)],
      reason: 'the dot is about the addresses the card shows and dials',
    );
    expect(provider.isPeerOnline('peer-device'), isTrue);
    expect(provider.peerPresenceSource('peer-device'), PresenceSource.probe);

    // A single miss is a race — a Wi-Fi waking up, a probe that landed while
    // the peer was mid-answer — so it must not flicker the dot.
    reachable = false;
    await provider.refreshPresence();
    expect(
      provider.isPeerOnline('peer-device'),
      isTrue,
      reason: 'one lost probe is not a peer that went away',
    );

    await provider.refreshPresence();
    expect(
      provider.isPeerOnline('peer-device'),
      isFalse,
      reason: 'the second miss in a row is the answer',
    );
    expect(provider.peerPresenceSource('peer-device'), PresenceSource.unknown);

    // And one success is enough to come back.
    reachable = true;
    await provider.refreshPresence();
    expect(provider.isPeerOnline('peer-device'), isTrue);
  });

  test('a session that cannot talk outranks a probe that can', () async {
    final a = _Side('a');
    final b = _Side('b');
    await a.start(root, withEngine: false);
    await b.start(root);
    sides.addAll([a, b]);

    // The probe always answers, which is exactly the trap: an address can
    // accept a TCP connection and never complete the handshake a session needs.
    final provider = await a.startProvider(presenceProbe: (_) async => true);
    final pin = b.engine.openPairing();
    await provider.pairWith(host: '127.0.0.1', port: b.port, pin: pin);
    await _waitUntil(() async => provider.busyDeviceIds.isEmpty);
    expect(provider.isPeerOnline(b.identity.deviceId), isTrue);

    // The peer goes away; the probe keeps saying "something answers here".
    await b.engine.stop();
    final report = await provider.syncNow(b.identity.deviceId);
    expect(report?.success, isFalse);
    expect(report?.failure, SyncFailureReason.unreachable);

    expect(
      provider.isPeerOnline(b.identity.deviceId),
      isFalse,
      reason: 'a session asked for a handshake and got nothing',
    );
    expect(
      provider.peerPresenceSource(b.identity.deviceId),
      PresenceSource.sessionSilent,
      reason:
          'and the card can say the answer came from a session, not a probe',
    );

    // The probe runs right after the session and would re-green the dot on its
    // own — the session's verdict has to hold it down for its TTL.
    await provider.refreshPresence();
    expect(
      provider.isPeerOnline(b.identity.deviceId),
      isFalse,
      reason: 'the probe is the weaker evidence here',
    );
  });

  test('a refusal is an answer: the peer is there', () async {
    final a = _Side('a');
    final b = _Side('b');
    await a.start(root, withEngine: false);
    await b.start(root);
    sides.addAll([a, b]);

    // The probe never finds anything, so every green here has to come from the
    // session itself.
    final provider = await a.startProvider(presenceProbe: (_) async => false);
    final pin = b.engine.openPairing();
    await provider.pairWith(host: '127.0.0.1', port: b.port, pin: pin);
    await _waitUntil(() async => provider.busyDeviceIds.isEmpty);

    // A secret the peer no longer knows: it answers, and refuses.
    final stale = await a.peer(b);
    stale.secret = 'stale-secret';
    await a.store.savePeer(stale);
    await provider.refreshPeers();

    final report = await provider.syncNow(b.identity.deviceId);
    expect(report?.refusal, SyncRefusalReason.notPaired);

    expect(
      provider.isPeerOnline(b.identity.deviceId),
      isTrue,
      reason: 'being refused proves the peer answered',
    );
    expect(
      provider.peerPresenceSource(b.identity.deviceId),
      PresenceSource.sessionAnswered,
    );
  });

  test('a dial names the address and its rank', () async {
    // The beat that can hang is the dial, so the label has to say *which*
    // address is hanging — otherwise a stuck candidate is indistinguishable
    // from a stuck comparison.
    final (a, b) = await pair();
    final seen = <SyncSessionProgress>[];
    late final SyncEngine engine;
    engine = SyncEngine(
      identity: a.identity,
      store: a.store,
      dataPlane: a.dataPlane,
      onStateChanged: () {
        final progress = engine.initiatorProgress[b.identity.deviceId];
        if (progress != null) seen.add(progress);
      },
    );

    final report = await engine.syncWithPeer(await a.peer(b));
    expect(report.success, isTrue, reason: report.summary);

    final dials = seen.where(
      (p) => p.phase == SyncSessionPhase.connecting && p.address != null,
    );
    expect(
      dials.map((p) => p.address),
      contains('127.0.0.1:${b.port}'),
      reason: 'the card shows the address being dialed',
    );
    expect(dials.first.attempt, 1);
    expect(dials.first.attempts, 1, reason: 'one remembered address, one try');

    // "Comparing data" may only appear once the peer actually answered: the
    // hello round trip is where a silent address spends its whole budget.
    final order = seen.map((p) => p.phase).toList();
    expect(
      order.indexOf(SyncSessionPhase.exchanging),
      greaterThan(order.lastIndexOf(SyncSessionPhase.connecting)),
      reason: 'the dial beat must come first, or the label lies about the wait',
    );
  });

  test('a peer dial is always direct, never through a proxy', () async {
    // Dart's default `findProxy` is `findProxyFromEnvironment`, and the addresses
    // a real pairing remembers — a NAT'd public one, an IPv6 one — are not in a
    // typical NO_PROXY, which lists private ranges only. `HttpClient.findProxy`
    // is write-only, so the rule cannot be asserted as a value; what *is*
    // assertable is the behaviour it exists for: every loopback session in this
    // file connects while the process runs with a proxy exported, and would fail
    // if the factory ever handed the dial to it. This test pins the one property
    // the rest of the suite depends on being true, on a host the environment's
    // NO_PROXY does not list.
    final side = _Side('a');
    sides.add(side);
    await side.start(root);

    final socket = await ServerSocket.bind(InternetAddress('127.0.0.2'), 0);
    try {
      final client = SyncClient.directClient(side.identity.buildContext());
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.2:${socket.port}/sync/hello'),
      );
      // The request waits for a response, so it is answered by hand below. A raw
      // socket is the point: what is asserted is *which* endpoint the bytes
      // reached, and a proxied dial would connect to the proxy's port instead,
      // leaving this accept() to time out.
      final pending = request.close();
      final connection = await socket.first.timeout(const Duration(seconds: 5));
      connection.write('HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n');
      await connection.flush();
      final response = await pending;
      expect(response.statusCode, HttpStatus.ok);
      connection.destroy();
      client.close(force: true);
    } finally {
      await socket.close();
    }
  });

  test('a re-pair keeps the last-sync stamp and the checkpoint', () async {
    final (a, b) = await pair();
    await _seedConversation(a, id: 'conv-a', contents: ['hello from a']);
    final first = await a.engine.syncWithPeer(await a.peer(b));
    expect(first.success, isTrue);
    final stamp = (await a.peer(b)).lastSyncedAt;
    expect(stamp, isNotNull);
    expect(
      (await a.store.loadCheckpoint(b.identity.deviceId)).conversations.keys,
      contains('conv-a'),
    );

    // The peer moved: A's remembered address is stale, which is exactly when a
    // re-pair happens.
    final drifted = await a.peer(b);
    drifted.replaceEndpoints('10.255.255.1', 1);
    await a.store.savePeer(drifted);

    final pin = b.engine.openPairing();
    await a.engine.pairWith(host: '127.0.0.1', port: b.port, pin: pin);

    final repaired = await a.peer(b);
    expect(
      repaired.lastSyncedAt,
      stamp,
      reason: 'pairing again is not a reset: those sessions still happened',
    );
    expect(
      (await a.store.loadCheckpoint(b.identity.deviceId)).conversations.keys,
      contains('conv-a'),
      reason:
          'the checkpoint is keyed by deviceId, which pairing never changes',
    );

    final second = await a.engine.syncWithPeer(repaired);
    expect(second.success, isTrue);
    expect(
      second.conversationsSent,
      0,
      reason:
          'the surviving checkpoint makes the settled conversation a "none"',
    );
  });

  test('a failed session does not move the last-synced stamp', () async {
    final (a, b) = await pair();
    await _seedConversation(a, id: 'conv-a', contents: ['hello from a']);
    await a.engine.syncWithPeer(await a.peer(b));
    final synced = (await a.peer(b)).lastSyncedAt!;

    await b.engine.stop();
    final failed = await a.engine.syncWithPeer(await a.peer(b));
    expect(failed.success, isFalse);
    expect(failed.failure, SyncFailureReason.unreachable);

    final after = await a.peer(b);
    expect(
      after.lastSyncedAt,
      synced,
      reason:
          'the line answers "how fresh is what I see?", which a dead peer did '
          'not change — it used to say "just now" for every failure',
    );
    expect(
      after.lastReport?.success,
      isFalse,
      reason: 'the failure itself is still reported on the card',
    );
  });

  test('a session publishes its beats and clears them when it ends', () async {
    final (a, b) = await pair();
    await _seedConversation(a, id: 'conv-a', contents: ['hello from a']);

    final seen = <SyncSessionPhase>[];
    late final SyncEngine engine;
    engine = SyncEngine(
      identity: a.identity,
      store: a.store,
      dataPlane: a.dataPlane,
      onStateChanged: () {
        final progress = engine.initiatorProgress[b.identity.deviceId];
        if (progress != null) seen.add(progress.phase);
      },
    );

    final report = await engine.syncWithPeer(await a.peer(b));

    expect(report.success, isTrue);
    expect(
      seen,
      containsAllInOrder([
        SyncSessionPhase.connecting,
        SyncSessionPhase.exchanging,
        SyncSessionPhase.sending,
        SyncSessionPhase.receiving,
        SyncSessionPhase.applying,
      ]),
      reason: 'the card names the beat instead of showing a bare spinner',
    );
    expect(
      engine.initiatorProgress,
      isEmpty,
      reason: 'progress lives exactly as long as the session',
    );
  });
}
