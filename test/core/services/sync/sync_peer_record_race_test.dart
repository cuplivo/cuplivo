// A peer record is written by two owners at once: the provider's panel (a
// rename, an endpoint edit, the measured latency) and the engine's session
// (`lastSyncedAt`, `lastReport`, the endpoint the session promoted). Every write
// used to be a whole-record `savePeer` of a copy read earlier, so the last writer
// won and the other's field was silently dropped — the post-session probe write
// erasing a successful session's own outcome, and a rename made while a session
// ran being erased by it.
//
// The fix has one choke point: `SyncStore.mutatePeer` reads the record *inside*
// a per-peer section and writes it back, so a mutation applies to what is on disk
// now. This test parks the responder inside its hello so the session is provably
// open, makes the panel's write land mid-session, and then asserts that both
// writes survive: the rename *and* the session's outcome.

import 'dart:async';
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/providers/sync_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/sync/business_state_reloader.dart';
import 'package:Cuplivo/core/services/sync/sync_data_plane.dart';
import 'package:Cuplivo/core/services/sync/sync_engine.dart';
import 'package:Cuplivo/core/services/sync/sync_identity.dart';
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

/// A data plane whose manifest build can be parked, so the responder's hello
/// stays unanswered while the test acts on the initiator.
class _GatedManifestPlane extends SyncDataPlane {
  _GatedManifestPlane({
    required super.repository,
    required super.chatService,
    required super.businessRepository,
    super.businessPreferences,
  });

  Completer<void>? gate;
  Completer<void>? entered;

  void arm() {
    gate = Completer<void>();
    entered = Completer<void>();
  }

  @override
  Future<SyncManifest> buildManifest() async {
    final parked = gate;
    if (parked != null) {
      entered?.complete();
      await parked.future;
    }
    return super.buildManifest();
  }
}

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
  SyncEngine? engine;
  int port = 0;
  SyncProvider? provider;

  Future<void> start(Directory root, {required bool withEngine}) async {
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
    dataPlane = _GatedManifestPlane(
      repository: repository,
      chatService: chatService,
      businessRepository: businessRepository,
      businessPreferences: businessPreferences,
    );
    if (!withEngine) return;
    final engine = SyncEngine(
      identity: identity,
      store: store,
      dataPlane: dataPlane,
      onStateChanged: () {},
    );
    this.engine = engine;
    port = await engine.start(preferredPort: 0);
  }

  Future<SyncProvider> startProvider() async {
    final started = SyncProvider(
      chatService: chatService,
      repository: repository,
      businessRepository: businessRepository,
      businessPreferences: businessPreferences,
      reloader: BusinessStateReloader(businessPreferences),
      syncDirectory: () async => dir,
      addressSource: () async => const [],
      endpointProbe: (host, port) async {},
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
      await engine?.stop();
    }
    await chatService.close();
    await repository.close();
  }
}

Future<void> _waitUntil(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition never became true');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory root;
  late PathProviderPlatform previousPathProvider;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cuplivo_peer_record_race_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPathProvider;
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  test('a rename during a session and the session\'s own outcome both '
      'survive', () async {
    final b = _Side('b');
    await b.start(root, withEngine: true);
    final a = _Side('a');
    await a.start(root, withEngine: false);
    final provider = await a.startProvider();

    try {
      final pin = b.engine!.openPairing();
      await provider.pairWith(host: '127.0.0.1', port: b.port, pin: pin);
      await _waitUntil(() async => provider.busyDeviceIds.isEmpty);

      final peerId = b.identity.deviceId;
      expect((await a.store.readPeer(peerId))!.customName, isNull);

      // Park the responder inside its hello, so the initiator's round is
      // provably still open when the panel's write lands.
      final plane = b.dataPlane as _GatedManifestPlane;
      plane.arm();
      final pending = provider.syncNow(peerId);
      await plane.entered!.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw StateError('the round never reached the peer'),
      );

      // The panel's own call, on the record the provider re-read from disk —
      // exactly what `refreshPeers` leaves in `SyncProvider.peers` once the
      // engine's session-start state change has fired.
      await provider.refreshPeers();
      await provider.renamePeer(peerId, 'renamed-during-session');
      expect(
        (await a.store.readPeer(peerId))!.customName,
        'renamed-during-session',
        reason: 'the panel write has to land while the session is open',
      );

      plane.gate!.complete();
      final report = await pending;
      expect(report, isNotNull);
      expect(report!.success, isTrue, reason: report.summary);

      // Both writes, in one record: the session's outcome is durable (the
      // post-session probe write merges into it instead of overwriting it from
      // a pre-session snapshot) and the rename the user made mid-session is
      // still there.
      final after = (await a.store.readPeer(peerId))!;
      expect(
        after.lastSyncedAt,
        isNotNull,
        reason: 'a successful session must not come back saying "never synced"',
      );
      expect(after.lastReport?.success, isTrue);
      expect(after.customName, 'renamed-during-session');

      // And the panel's own list — what the card renders — agrees after the
      // session's refresh.
      await provider.refreshPeers();
      final inProvider = provider.peers.firstWhere((p) => p.deviceId == peerId);
      expect(inProvider.lastSyncedAt, isNotNull);
      expect(inProvider.lastReport?.success, isTrue);
      expect(inProvider.customName, 'renamed-during-session');
    } finally {
      await a.dispose();
      await b.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
