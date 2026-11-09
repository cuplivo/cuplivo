// A premise is re-read where it is used.
//
// One sync write or delete may only be judged by the state it was computed
// from. The half that changes — local rows, local files, the workspace switch,
// the history — is read again at the moment the write happens; the half that
// cannot change mid-session (the peer's manifest, which came with its hello,
// and the checkpoint, which came from disk) travels with the plan instead.
//
// Both faces of that rule are the same function asked a second time:
// `planRowSync` / `planWorkspaceContent` re-run against fresh local state. What
// the two faces are *not* allowed to do is share a reading: "the payload we
// sent" names a checkpoint entry, and "the row that is here now" names an
// action.
//
// One case per cell of the state table in the plan. Each case is here rather
// than in sync_engine_integration_test.dart because that file is the one place
// PR1-PR4 all land in.

import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/sync/sync_data_plane.dart';
import 'package:Cuplivo/core/services/sync/sync_engine.dart';
import 'package:Cuplivo/core/services/sync/sync_identity.dart';
import 'package:Cuplivo/core/services/sync/sync_merge.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:Cuplivo/core/services/sync/sync_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

/// One device: its own database, its own sync directory, a real listener.
class _Side {
  _Side(this.label);

  final String label;
  late final Directory dir;
  late final AppDatabase database;
  late final ChatDatabaseRepository repository;
  late final ChatService chatService;
  late final BusinessRepository businessRepository;
  late final BusinessPreferences businessPreferences;
  late final SyncDeviceIdentity identity;
  late final SyncStore store;
  late final SyncDataPlane dataPlane;
  late final SyncEngine engine;
  int port = 0;

  /// Runs once, at the one moment a session has packed its business rows and
  /// has not yet advanced the checkpoint for them — the window in which a user
  /// edit is invisible to the payload that is already on its way.
  Future<void> Function()? editAfterBusinessRead;

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
    dataPlane = _PremisePlane(this);
    engine = SyncEngine(
      identity: identity,
      store: store,
      dataPlane: dataPlane,
      onStateChanged: () {},
    );
    port = await engine.start(preferredPort: 0);
  }

  Future<SyncPeerRecord> peer(_Side other) async {
    final record = await store.findPeer(other.identity.deviceId);
    if (record == null) {
      throw StateError('$label has no record for ${other.label}');
    }
    return record;
  }

  Future<void> dispose() async {
    await engine.stop();
    await chatService.close();
    await repository.close();
  }
}

/// The data plane with one seam: a hook between "the rows are packed" and
/// "the checkpoint describes them".
class _PremisePlane extends SyncDataPlane {
  _PremisePlane(this.side)
    : super(
        repository: side.repository,
        chatService: side.chatService,
        businessRepository: side.businessRepository,
        businessPreferences: side.businessPreferences,
      );

  final _Side side;

  @override
  Future<({SyncBusinessPayload payload, Set<String> keys})> readBusinessRows({
    required Map<String, Set<String>> entityIds,
    required Set<String> preferenceKeys,
  }) async {
    final read = await super.readBusinessRows(
      entityIds: entityIds,
      preferenceKeys: preferenceKeys,
    );
    final edit = side.editAfterBusinessRead;
    if (edit != null) {
      side.editAfterBusinessRead = null;
      await edit();
    }
    return read;
  }
}

/// The value this device currently holds for [key], decoded.
///
/// A preference's stored string is its JSON form, so these assertions compare
/// the value and not its encoding.
Future<Object?> _preferenceValue(_Side side, String key) async {
  final rows = await side.businessRepository.syncReadPreferenceRows({key});
  if (rows.isEmpty) return null;
  return jsonDecode(rows.first['value'] as String);
}

/// The checkpoint digest this device's stored row for [key] produces.
///
/// Derived from the stored string rather than from the value written through the
/// API, so the assertion is about *which row* the entry names and not about how
/// a preference happens to be encoded on disk.
Future<String> _storedDigest(_Side side, String key) async {
  final row = (await side.businessRepository.syncReadPreferenceRows({
    key,
  })).single;
  return businessContentDigest(row['value'] as String);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  late PathProviderPlatform previousPathProvider;

  /// Two paired devices: [a] initiates, [b] answers.
  Future<({_Side a, _Side b})> pair() async {
    final a = _Side('a');
    await a.start(root);
    final b = _Side('b');
    await b.start(root);
    final pin = b.engine.openPairing();
    await a.engine.pairWith(host: '127.0.0.1', port: b.port, pin: pin);
    addTearDown(() async {
      await a.dispose();
      await b.dispose();
    });
    return (a: a, b: b);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cuplivo_premise_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPathProvider;
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  group('a premise is re-read where it is used', () {
    test(
      'a sent business row is checkpointed as sent, not as it now stands',
      () async {
        final (:a, :b) = await pair();
        await a.businessPreferences.setString('user_name', 'sent-value');
        final sentDigest = await _storedDigest(a, 'user_name');

        // The edit lands after the push read the row and before the checkpoint
        // describes it: the row that travelled is 'sent-value', the row that is
        // here is 'edited-value'.
        a.editAfterBusinessRead = () =>
            a.businessPreferences.setString('user_name', 'edited-value');

        final first = await a.engine.syncWithPeer(await a.peer(b));
        expect(first.success, isTrue, reason: first.summary);
        final editedDigest = await _storedDigest(a, 'user_name');
        expect(sentDigest, isNot(editedDigest));

        // The evidence face: the entry names what crossed the wire.
        final entry = (await a.store.loadCheckpoint(
          b.identity.deviceId,
        )).preferences['user_name'];
        expect(
          entry?.digest,
          sentDigest,
          reason:
              'a checkpoint entry claims what the peer holds, and the peer '
              'holds the row that was pushed',
        );
        expect(
          entry?.digest,
          isNot(editedDigest),
          reason: 'an unsent edit must never be recorded as peer-seen',
        );
        expect(await _preferenceValue(b, 'user_name'), 'sent-value');

        // The damage the old reading did is not a missed send, it is a pull:
        // with the edit in the checkpoint, the next session plans
        // `mine == checkpoint` and concludes the peer has newer content.
        await a.engine.syncWithPeer(await a.peer(b));
        expect(
          await _preferenceValue(b, 'user_name'),
          'edited-value',
          reason: 'the next session must deliver the edit the first one missed',
        );
        expect(
          await _preferenceValue(a, 'user_name'),
          'edited-value',
          reason: "the peer's older row must not replace the local edit",
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
