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
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:Cuplivo/core/services/sync/sync_pair_qr.dart';
import 'package:Cuplivo/core/services/sync/sync_store.dart';
import 'package:Cuplivo/features/sync/widgets/sync_pairing_dialogs.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
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
  /// pairing and the foreground round live in.
  Future<SyncProvider> startProvider() async {
    final started = SyncProvider(
      chatService: chatService,
      repository: repository,
      businessRepository: businessRepository,
      businessPreferences: businessPreferences,
      reloader: BusinessStateReloader(businessPreferences),
      syncDirectory: () async => dir,
    );
    provider = started;
    await started.start();
    port = started.port ?? 0;
    return started;
  }

  Future<void> dispose() async {
    final viaProvider = provider;
    if (viaProvider != null) {
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
    expect(aPeer.lastHost, '127.0.0.1');
    expect(aPeer.lastPort, b.port);
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

    // Pretend the peer moved: A's stored endpoint is stale.
    final drifted = await a.peer(b);
    final staleSecret = drifted.secret;
    drifted.lastHost = '10.255.255.1';
    drifted.lastPort = 1;
    await a.store.savePeer(drifted);

    final pin = b.engine.openPairing();
    await a.engine.pairWith(
      host: '127.0.0.1',
      port: b.port,
      pin: pin,
      expectedDeviceId: b.identity.deviceId,
    );

    final refreshed = await a.peer(b);
    expect(refreshed.lastHost, '127.0.0.1');
    expect(
      refreshed.lastPort,
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
      lastHost: '127.0.0.1',
      lastPort: b.port,
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
      expect(peer.lastPort, b.port, reason: 'the live candidate won');
      // The joiner advertised its own listener, so the responder can dial back.
      expect((await b.peer(a)).lastPort, provider.port);

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

  test('a pending blob retry survives a session with nothing to push', () async {
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
  });

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
        persisted.error,
        isNull,
        reason: 'a refusal, not a raw 401 transport string',
      );
    },
  );

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
}
