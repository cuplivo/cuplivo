import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_preferences_store.dart';
import 'package:Cuplivo/core/providers/auto_snapshot_provider.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/services/backup/auto_snapshot_service.dart';
import 'package:Cuplivo/core/services/backup/backup_activity_gate.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';

/// Timing-controllable fake: [createSnapshot] may be gated on a [Completer]
/// so tests can interleave a disable with an in-flight snapshot.
class _FakeAutoSnapshotService extends AutoSnapshotService {
  _FakeAutoSnapshotService()
    : super(
        exportBackup: () async => throw UnsupportedError('stubbed out'),
        assistantCount: () async => 0,
        conversationCount: () async => 0,
        messageCount: () async => 0,
      );

  Completer<void>? createGate;
  Completer<void>? deleteGate;
  bool deleteWhileCreatePending = false;
  bool failCreate = false;
  bool failDelete = false;
  int failListTimes = 0;
  bool _createCompleted = false;
  final List<SnapshotMetadata> store = [];

  @override
  Future<AutoSnapshotResult> createSnapshot() async {
    if (failCreate) throw StateError('export failed');
    final gate = createGate;
    if (gate != null) await gate.future;
    final meta = SnapshotMetadata(
      fileName: 'auto_snapshot_20260830T000000.zip',
      createdAt: DateTime.now(),
      sizeBytes: 1,
      assistantCount: 0,
      conversationCount: 0,
      messageCount: 0,
      contentHash: 'fake-hash',
    );
    store
      ..clear()
      ..add(meta);
    _createCompleted = true;
    return AutoSnapshotResult(AutoSnapshotStatus.created, meta);
  }

  @override
  Future<List<SnapshotMetadata>> listSnapshots() async {
    if (failListTimes > 0) {
      failListTimes--;
      throw StateError('listing failed');
    }
    return List.of(store);
  }

  @override
  Future<void> deleteAllSnapshots() async {
    if (failDelete) throw StateError('disk locked');
    final gate = deleteGate;
    if (gate != null) await gate.future;
    deleteWhileCreatePending = !_createCompleted;
    store.clear();
  }
}

/// A store whose writes can be made to fail on demand — the persistence
/// equivalent of the delete/create gates. Mirrors [MemoryBusinessStore] so
/// the facade behaves exactly like `memoryForTests` otherwise.
class _ThrowingBusinessStore implements BusinessPreferencesStore {
  final MemoryBusinessStore _inner = MemoryBusinessStore();

  bool throwOnWrite = false;
  bool throwOnRemove = false;

  @override
  Future<List<BusinessPreferenceEntry>> readAll() => _inner.readAll();

  @override
  Future<void> write(String key, Object value, {required int updatedAt}) async {
    if (throwOnWrite) throw StateError('disk error');
    await _inner.write(key, value, updatedAt: updatedAt);
  }

  @override
  Future<void> remove(String key) async {
    if (throwOnRemove) throw StateError('remove failed');
    await _inner.remove(key);
  }

  @override
  Future<void> clear() => _inner.clear();

  Future<void> seed(String key, Object value, {int? updatedAt}) =>
      _inner.seed(key, value, updatedAt: updatedAt);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'setEnabled(false) waits for an in-flight snapshot before deleting',
    () async {
      final fake = _FakeAutoSnapshotService()..createGate = Completer<void>();
      final provider = AutoSnapshotProvider(
        preferences: BusinessPreferences.memoryForTests({}),
        chatService: ChatService(),
        autoLoad: false,
        serviceFactory: () => fake,
      );
      await provider.load();

      await provider.setEnabled(true);
      await pumpEventQueue();
      expect(
        provider.busy,
        isTrue,
        reason: 'baseline snapshot should be in flight',
      );

      final disableFuture = provider.setEnabled(false);
      await pumpEventQueue();
      fake.createGate!.complete();
      await disableFuture;
      await pumpEventQueue();

      expect(
        fake.deleteWhileCreatePending,
        isFalse,
        reason: 'delete must run only after the in-flight snapshot completes',
      );
      expect(fake.store, isEmpty);
      expect(provider.snapshots, isEmpty);
      expect(provider.lastSnapshotAt, isNull);
    },
  );

  test(
    'setEnabled(false) with delete removes snapshots created this session',
    () async {
      final fake = _FakeAutoSnapshotService();
      final provider = AutoSnapshotProvider(
        preferences: BusinessPreferences.memoryForTests({}),
        chatService: ChatService(),
        autoLoad: false,
        serviceFactory: () => fake,
      );
      await provider.load();

      await provider.setEnabled(true);
      await pumpEventQueue();
      expect(provider.snapshots, hasLength(1));

      await provider.setEnabled(false);

      expect(fake.store, isEmpty);
      expect(provider.snapshots, isEmpty);
      expect(provider.enabled, isFalse);
    },
  );

  test(
    'a manual create is rejected once a delete teardown has started',
    () async {
      final fake = _FakeAutoSnapshotService()..deleteGate = Completer<void>();
      final provider = AutoSnapshotProvider(
        preferences: BusinessPreferences.memoryForTests({}),
        chatService: ChatService(),
        autoLoad: false,
        serviceFactory: () => fake,
      );
      await provider.load();

      await provider.setEnabled(true);
      await pumpEventQueue();
      expect(provider.snapshots, hasLength(1));

      final disableFuture = provider.setEnabled(false);
      await pumpEventQueue();
      expect(fake.store, hasLength(1), reason: 'delete still pending');

      // The teardown has started: a new attempt (e.g. the manual button) is
      // rejected before it can race the delete.
      final outcome = await provider.createSnapshot();
      expect(outcome, AutoSnapshotOutcome.skipped);
      expect(fake.store, hasLength(1), reason: 'nothing new was written');

      fake.deleteGate!.complete();
      await disableFuture;
      await pumpEventQueue();
      expect(fake.store, isEmpty);

      // With the feature off the manual attempt stays rejected too.
      expect(await provider.createSnapshot(), AutoSnapshotOutcome.skipped);
    },
  );

  test('an enable requested during teardown queues behind the disable and '
      'then owns state, persistence, and the baseline', () async {
    final fake = _FakeAutoSnapshotService()..deleteGate = Completer<void>();
    final prefs = BusinessPreferences.memoryForTests({});
    final provider = AutoSnapshotProvider(
      preferences: prefs,
      chatService: ChatService(),
      autoLoad: false,
      serviceFactory: () => fake,
    );
    await provider.load();

    await provider.setEnabled(true);
    await pumpEventQueue();
    expect(provider.snapshots, hasLength(1), reason: 'baseline snapshot');

    final disableFuture = provider.setEnabled(false, deleteSnapshots: true);
    await pumpEventQueue();
    expect(provider.enabled, isFalse);
    expect(
      prefs.getBool('auto_snapshot_enabled_v1'),
      isFalse,
      reason: 'disable persisted before the gated delete',
    );
    expect(fake.store, hasLength(1), reason: 'delete still pending');

    // Enable arrives while the teardown is inside the gated delete: it
    // must not touch any state or run a baseline while the delete is still
    // to complete.
    final enableFuture = provider.setEnabled(true);
    await pumpEventQueue();
    expect(
      provider.enabled,
      isFalse,
      reason: 'enable is queued, not applied during teardown',
    );
    expect(
      prefs.getBool('auto_snapshot_enabled_v1'),
      isFalse,
      reason: 'no persisted write happened while queued',
    );
    expect(fake.store, hasLength(1), reason: 'no baseline while queued');

    fake.deleteGate!.complete();
    await disableFuture;
    // The enable runs as soon as the disable completes (FIFO). Whether the
    // delete truly happened BEFORE the queued baseline is proven by the
    // final `hasLength(1)` below: a baseline written first would have been
    // wiped by the delete and the store would end up empty.
    await enableFuture;
    await pumpEventQueue();
    expect(provider.enabled, isTrue);
    expect(prefs.getBool('auto_snapshot_enabled_v1'), isTrue);
    expect(
      fake.store,
      hasLength(1),
      reason: 'exactly one surviving baseline snapshot',
    );
    expect(provider.lastSnapshotAt, isNotNull);
    expect(provider.snapshots, hasLength(1));
    // The queued enable started its own ticker; no second snapshot fires
    // within this test's window (the 1-minute cadence is not due).
    await pumpEventQueue();
    expect(fake.store, hasLength(1));
  });

  test(
    'a failed enable persistence write leaves the toggle retryable',
    () async {
      final store = _ThrowingBusinessStore();
      await store.seed('auto_snapshot_enabled_v1', false);
      final prefs = BusinessPreferences.open(store);
      await prefs.load();
      final fake = _FakeAutoSnapshotService();
      final provider = AutoSnapshotProvider(
        preferences: prefs,
        chatService: ChatService(),
        autoLoad: false,
        serviceFactory: () => fake,
      );
      await provider.load();
      expect(provider.enabled, isFalse);

      // The durable write fails: nothing may be published in memory, no
      // ticker/baseline may start, and a retry must be accepted.
      store.throwOnWrite = true;
      await expectLater(provider.setEnabled(true), throwsA(isA<StateError>()));
      expect(provider.enabled, isFalse, reason: 'in-memory state untouched');
      expect(prefs.getBool('auto_snapshot_enabled_v1'), isFalse);
      expect(fake.store, isEmpty, reason: 'no baseline ran');
      expect(provider.snapshots, isEmpty);

      store.throwOnWrite = false;
      await provider.setEnabled(true);
      await pumpEventQueue();
      expect(provider.enabled, isTrue);
      expect(prefs.getBool('auto_snapshot_enabled_v1'), isTrue);
      expect(
        fake.store,
        hasLength(1),
        reason: 'baseline snapshot created on the retried enable',
      );
    },
  );

  test(
    'a failed disable persistence write rolls back and stays retryable',
    () async {
      final store = _ThrowingBusinessStore();
      final prefs = BusinessPreferences.open(store);
      await prefs.load();
      final fake = _FakeAutoSnapshotService();
      final provider = AutoSnapshotProvider(
        preferences: prefs,
        chatService: ChatService(),
        autoLoad: false,
        serviceFactory: () => fake,
      );
      await provider.load();
      expect(provider.enabled, isFalse);

      // Session start: enabled, with a baseline snapshot (and anchor) to be
      // deleted by the disable retry.
      await provider.setEnabled(true);
      await pumpEventQueue();
      expect(provider.enabled, isTrue);
      expect(fake.store, hasLength(1));

      store.throwOnWrite = true;
      await expectLater(provider.setEnabled(false), throwsA(isA<StateError>()));
      expect(
        provider.enabled,
        isTrue,
        reason: 'in-memory state rolled back to enabled',
      );
      expect(prefs.getBool('auto_snapshot_enabled_v1'), isTrue);
      expect(fake.store, hasLength(1), reason: 'delete never ran');
      expect(provider.lastSnapshotAt, isNotNull);

      store.throwOnWrite = false;
      await provider.setEnabled(false);
      await pumpEventQueue();
      expect(provider.enabled, isFalse);
      expect(prefs.getBool('auto_snapshot_enabled_v1'), isFalse);
      expect(fake.store, isEmpty, reason: 'delete ran on the retry');
      expect(provider.lastSnapshotAt, isNull, reason: 'anchor cleared');
    },
  );

  test('a failed delete rolls back to enabled, keeps the store restorable, and '
      'retries on the next toggle', () async {
    final fake = _FakeAutoSnapshotService()..failDelete = true;
    final prefs = BusinessPreferences.memoryForTests({});
    final provider = AutoSnapshotProvider(
      preferences: prefs,
      chatService: ChatService(),
      autoLoad: false,
      serviceFactory: () => fake,
    );
    await provider.load();

    await provider.setEnabled(true);
    await pumpEventQueue();
    expect(provider.snapshots, hasLength(1));

    // The confirmed deletion did not finish: the disable as a whole fails
    // and rolls back to enabled — the switch shows on, so the user can
    // re-tap OFF to retry the same intent (consent is re-requested by the
    // page confirmation dialog).
    await expectLater(provider.setEnabled(false), throwsA(isA<StateError>()));
    expect(provider.enabled, isTrue);
    expect(prefs.getBool('auto_snapshot_enabled_v1'), isTrue);
    expect(provider.snapshots, hasLength(1), reason: 'files kept');

    fake.failDelete = false;
    await provider.setEnabled(false);
    await pumpEventQueue();
    expect(provider.enabled, isFalse);
    expect(prefs.getBool('auto_snapshot_enabled_v1'), isFalse);
    expect(fake.store, isEmpty, reason: 'retry completed the deletion');
  });

  test('an anchor write failure reports the committed snapshot as success and '
      'keeps the list truthful', () async {
    final store = _ThrowingBusinessStore();
    await store.seed('auto_snapshot_enabled_v1', false);
    final prefs = BusinessPreferences.open(store);
    await prefs.load();
    final fake = _FakeAutoSnapshotService();
    final provider = AutoSnapshotProvider(
      preferences: prefs,
      chatService: ChatService(),
      autoLoad: false,
      serviceFactory: () => fake,
    );
    await provider.load();
    await provider.setEnabled(true);
    await pumpEventQueue();
    final baselineAt = provider.lastSnapshotAt;
    expect(provider.snapshots, hasLength(1));
    expect(baselineAt, isNotNull);

    // The snapshot commits, the cadence-anchor write is rejected.
    store.throwOnWrite = true;
    final outcome = await provider.createSnapshot();
    expect(outcome, AutoSnapshotOutcome.created);
    expect(
      provider.lastSnapshotAt,
      baselineAt,
      reason: 'scheduling anchor restored so the next tick can retry',
    );
    expect(provider.snapshots, hasLength(1), reason: 'list refreshed');
    expect(fake.store, hasLength(1));

    // Fault clears: the next attempt persists the anchor again.
    store.throwOnWrite = false;
    await provider.createSnapshot();
    expect(provider.lastSnapshotAt, isNotNull);
    expect(prefs.getString('auto_snapshot_last_snapshot_at_v1'), isNotNull);
    provider.dispose();
  });

  test('a failed interval write leaves the published interval untouched and '
      'retryable', () async {
    final store = _ThrowingBusinessStore();
    final prefs = BusinessPreferences.open(store);
    await prefs.load();
    final provider = AutoSnapshotProvider(
      preferences: prefs,
      chatService: ChatService(),
      autoLoad: false,
      serviceFactory: () => _FakeAutoSnapshotService(),
    );
    await provider.load();
    expect(
      provider.intervalMinutes,
      AutoSnapshotProvider.presetIntervalMinutes[1],
    );

    store.throwOnWrite = true;
    await expectLater(
      provider.setIntervalMinutes(720),
      throwsA(isA<StateError>()),
    );
    expect(
      provider.intervalMinutes,
      AutoSnapshotProvider.presetIntervalMinutes[1],
      reason: 'nothing published on a rejected write',
    );

    store.throwOnWrite = false;
    await provider.setIntervalMinutes(720);
    expect(provider.intervalMinutes, 720);
    expect(prefs.getInt('auto_snapshot_interval_minutes_v1'), 720);
    provider.dispose();
  });

  test(
    'a listing failure keeps the last known list and later refresh clears it',
    () async {
      final fake = _FakeAutoSnapshotService();
      final provider = AutoSnapshotProvider(
        preferences: BusinessPreferences.memoryForTests({}),
        chatService: ChatService(),
        autoLoad: false,
        serviceFactory: () => fake,
      );
      await provider.load();
      await provider.setEnabled(true);
      await pumpEventQueue();
      expect(provider.snapshots, hasLength(1));

      fake.failListTimes = 1;
      await provider.refreshSnapshots();
      expect(provider.listError, isNotNull);
      expect(
        provider.snapshots,
        hasLength(1),
        reason: 'an unknown store is never presented as empty',
      );

      await provider.refreshSnapshots();
      expect(provider.listError, isNull);
      expect(provider.snapshots, hasLength(1));

      await provider.setEnabled(false);
      await pumpEventQueue();
      expect(fake.store, isEmpty);
    },
  );

  test('a failed anchor removal during disable rolls back and retries on the '
      'next toggle', () async {
    final store = _ThrowingBusinessStore();
    final prefs = BusinessPreferences.open(store);
    await prefs.load();
    final fake = _FakeAutoSnapshotService();
    final provider = AutoSnapshotProvider(
      preferences: prefs,
      chatService: ChatService(),
      autoLoad: false,
      serviceFactory: () => fake,
    );
    await provider.load();
    await provider.setEnabled(true);
    await pumpEventQueue();
    expect(provider.enabled, isTrue);
    expect(provider.snapshots, hasLength(1));

    store.throwOnRemove = true;
    await expectLater(provider.setEnabled(false), throwsA(isA<StateError>()));
    expect(provider.enabled, isTrue, reason: 'rolled back to enabled');
    expect(prefs.getBool('auto_snapshot_enabled_v1'), isTrue);
    expect(fake.store, hasLength(1), reason: 'delete never ran');

    store.throwOnRemove = false;
    await provider.setEnabled(false);
    await pumpEventQueue();
    expect(provider.enabled, isFalse);
    expect(prefs.getBool('auto_snapshot_enabled_v1'), isFalse);
    expect(fake.store, isEmpty);
    expect(provider.lastSnapshotAt, isNull);
    provider.dispose();
  });

  test('baseline success stashes a one-shot notice for the UI', () async {
    final fake = _FakeAutoSnapshotService();
    final provider = AutoSnapshotProvider(
      preferences: BusinessPreferences.memoryForTests({}),
      chatService: ChatService(),
      autoLoad: false,
      serviceFactory: () => fake,
    );
    await provider.load();

    await provider.setEnabled(true);
    await pumpEventQueue();

    final notice = provider.pendingNotice;
    expect(notice, isNotNull);
    expect(notice!.outcome, AutoSnapshotOutcome.created);
    expect(notice.error, isNull);
    provider.consumeNotice();
    expect(provider.pendingNotice, isNull);
  });

  test('baseline failure stashes a failed notice with the error', () async {
    final fake = _FakeAutoSnapshotService()..failCreate = true;
    final provider = AutoSnapshotProvider(
      preferences: BusinessPreferences.memoryForTests({}),
      chatService: ChatService(),
      autoLoad: false,
      serviceFactory: () => fake,
    );
    await provider.load();

    await provider.setEnabled(true);
    await pumpEventQueue();

    final notice = provider.pendingNotice;
    expect(notice, isNotNull);
    expect(notice!.outcome, AutoSnapshotOutcome.failed);
    expect(notice.error, isNotNull);
    expect(provider.lastError, isNotNull);
  });

  test('a due tick stashes a one-shot notice via load', () async {
    final fake = _FakeAutoSnapshotService();
    final provider = AutoSnapshotProvider(
      preferences: BusinessPreferences.memoryForTests({
        'auto_snapshot_enabled_v1': true,
      }),
      chatService: ChatService(),
      autoLoad: false,
      serviceFactory: () => fake,
    );
    // No last-snapshot anchor → the first due evaluation fires a snapshot.
    await provider.load();
    await pumpEventQueue();

    final notice = provider.pendingNotice;
    expect(notice, isNotNull);
    expect(notice!.outcome, AutoSnapshotOutcome.created);
    expect(fake.store, hasLength(1));
    provider.consumeNotice();
    expect(provider.pendingNotice, isNull);
  });

  test('a skipped attempt never stashes a notice', () async {
    final gateCompleter = Completer<void>();
    final held = BackupActivityGate.scoped(() => gateCompleter.future);
    final fake = _FakeAutoSnapshotService();
    final provider = AutoSnapshotProvider(
      preferences: BusinessPreferences.memoryForTests({
        'auto_snapshot_enabled_v1': true,
      }),
      chatService: ChatService(),
      autoLoad: false,
      serviceFactory: () => fake,
    );
    await provider.load();
    await pumpEventQueue();

    // The due evaluation found the gate held by another backup-family op and
    // deferred — no outcome was stashed.
    expect(provider.pendingNotice, isNull);
    expect(fake.store, isEmpty);

    gateCompleter.complete();
    await held;
    await pumpEventQueue();
  });
}
