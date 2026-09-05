import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/providers/auto_snapshot_provider.dart';
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
  Future<List<SnapshotMetadata>> listSnapshots() async => List.of(store);

  @override
  Future<void> deleteAllSnapshots() async {
    if (failDelete) throw StateError('disk locked');
    final gate = deleteGate;
    if (gate != null) await gate.future;
    deleteWhileCreatePending = !_createCompleted;
    store.clear();
  }
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
    'a failed delete surfaces to the caller and keeps the store restorable',
    () async {
      final fake = _FakeAutoSnapshotService()..failDelete = true;
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

      await expectLater(provider.setEnabled(false), throwsA(isA<StateError>()));

      // Disable still completes (feature off, prefs written); the failure is a
      // surfaced error and the remaining snapshots stay visible/restorable.
      expect(provider.enabled, isFalse);
      expect(provider.snapshots, hasLength(1));
    },
  );

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
