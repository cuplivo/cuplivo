import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/providers/auto_snapshot_provider.dart';
import 'package:Cuplivo/core/services/backup/auto_snapshot_service.dart';
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
  bool deleteWhileCreatePending = false;
  bool _createCompleted = false;
  final List<SnapshotMetadata> store = [];

  @override
  Future<AutoSnapshotResult> createSnapshot() async {
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
}
