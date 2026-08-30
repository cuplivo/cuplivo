import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/backup.dart';
import 'package:Cuplivo/core/services/sync/lan_sync_models.dart';

void main() {
  group('SyncPlan file payload fields', () {
    SyncPlan plan({int? serverFileCount, int? serverFileSizeBytes}) => SyncPlan(
      conversations: const [],
      missingAssistantIds: const [],
      remoteMissingAssistantIds: const [],
      since: DateTime(2026, 1, 1),
      serverFileCount: serverFileCount,
      serverFileSizeBytes: serverFileSizeBytes,
    );

    test('round-trips server file stats', () {
      final p = plan(serverFileCount: 12, serverFileSizeBytes: 3456);
      final decoded = SyncPlan.fromJsonString(p.toJsonString());
      expect(decoded.serverFileCount, 12);
      expect(decoded.serverFileSizeBytes, 3456);
      expect(decoded.since, DateTime(2026, 1, 1));
    });

    test('round-trips without file stats (null)', () {
      final p = plan();
      expect(p.toJsonString(), isNot(contains('serverFileCount')));
      final decoded = SyncPlan.fromJsonString(p.toJsonString());
      expect(decoded.serverFileCount, isNull);
      expect(decoded.serverFileSizeBytes, isNull);
    });

    test('old-format JSON without file keys parses as null', () {
      final raw = jsonEncode({
        'conversations': <dynamic>[],
        'missingAssistantIds': <dynamic>[],
        'remoteMissingAssistantIds': <dynamic>[],
        'since': '2026-01-01T00:00:00.000',
      });
      final decoded = SyncPlan.fromJsonString(raw);
      expect(decoded.serverFileCount, isNull);
      expect(decoded.serverFileSizeBytes, isNull);
      expect(decoded.since, DateTime(2026, 1, 1));
    });

    test('conversation-level plan round-trips unchanged', () {
      final p = SyncPlan(
        conversations: const [
          SyncConvPlan(
            conversationId: 'c1',
            conversationTitle: 'Chat 1',
            state: SyncConvState.initiatorOnly,
            initiatorIncrementCount: 3,
            serverIncrementCount: 0,
          ),
        ],
        missingAssistantIds: const ['a1'],
        remoteMissingAssistantIds: const <String>[],
        since: DateTime(2026, 1, 1),
        serverFileCount: 7,
        serverFileSizeBytes: 123,
      );
      final decoded = SyncPlan.fromJsonString(p.toJsonString());
      expect(decoded.initiatorOnlyCount, 1);
      expect(decoded.conversations.single.forkPointMessageId, isNull);
      expect(decoded.missingAssistantIds, ['a1']);
      expect(decoded.serverFileCount, 7);
    });
  });

  group('file manifest serialization', () {
    test('SyncIndex round-trips fileManifest', () {
      final original = SyncIndex(
        conversations: {
          'c1': ['m1'],
        },
        assistantIds: ['a1'],
        fileManifest: {
          'workspaces/x': const FileManifestEntry(size: 12, mtimeMs: 12345),
          'upload/a.png': const FileManifestEntry(size: 3, mtimeMs: 67890),
        },
      );
      final restored = SyncIndex.fromJsonString(original.toJsonString());
      expect(restored.conversations, original.conversations);
      expect(restored.fileManifest?['workspaces/x']?.size, 12);
      expect(restored.fileManifest?['workspaces/x']?.mtimeMs, 12345);
      expect(restored.fileManifest?['upload/a.png']?.mtimeMs, 67890);
    });

    test('SyncIndex without fileManifest parses (old peer)', () {
      const original = SyncIndex(conversations: {}, assistantIds: []);
      final restored = SyncIndex.fromJsonString(original.toJsonString());
      expect(restored.fileManifest, isNull);
    });

    test('SyncConvPlan round-trips its per-conversation since', () {
      final original = SyncConvPlan(
        conversationId: 'c1',
        state: SyncConvState.initiatorOnly,
        forkPointMessageId: 'm2',
        initiatorIncrementCount: 1,
        serverIncrementCount: 0,
        since: DateTime(2025, 1, 15, 10, 30),
      );
      final restored = SyncConvPlan.fromJson(
        Map<String, dynamic>.from(original.toJson()),
      );
      expect(restored.since, DateTime(2025, 1, 15, 10, 30));
    });

    test('SyncConvPlan without since parses (old format)', () {
      final json = <String, dynamic>{
        'conversationId': 'c1',
        'state': 'identical',
        'forkPointMessageId': null,
        'initiatorIncrementCount': 0,
        'serverIncrementCount': 0,
      };
      final restored = SyncConvPlan.fromJson(json);
      expect(restored.since, isNull);
    });

    test('SyncPlan round-trips serverFileManifest', () {
      final original = SyncPlan(
        conversations: const [],
        missingAssistantIds: const [],
        remoteMissingAssistantIds: const [],
        since: null,
        serverFileManifest: {
          'workspaces/x': const FileManifestEntry(size: 1, mtimeMs: 99),
        },
      );
      final restored = SyncPlan.fromJsonString(original.toJsonString());
      expect(restored.serverFileManifest?['workspaces/x']?.mtimeMs, 99);
    });

    test('SyncPlan without serverFileManifest parses (old format)', () {
      const original = SyncPlan(
        conversations: [],
        missingAssistantIds: [],
        remoteMissingAssistantIds: [],
        since: null,
      );
      final restored = SyncPlan.fromJsonString(original.toJsonString());
      expect(restored.serverFileManifest, isNull);
    });
  });

  group('SyncPriority (issue #615)', () {
    SyncIndex index({SyncPriority? priority}) => SyncIndex(
      conversations: {
        'c1': ['m1'],
      },
      assistantIds: const ['a1'],
      syncPriority: priority,
    );

    test('round-trips initiatorWins / serverWins', () {
      for (final priority in [
        SyncPriority.initiatorWins,
        SyncPriority.serverWins,
      ]) {
        final restored = SyncIndex.fromJsonString(
          index(priority: priority).toJsonString(),
        );
        expect(restored.syncPriority, priority);
      }
    });

    test('null (auto) serializes without the key and parses as null', () {
      final json = index().toJsonString();
      expect(json, isNot(contains('syncPriority')));
      expect(SyncIndex.fromJsonString(json).syncPriority, isNull);
    });

    test('old-format JSON without syncPriority parses as null', () {
      final raw = jsonEncode({
        'conversations': {
          'c1': ['m1'],
        },
        'assistantIds': ['a1'],
        'fileManifest': null,
      });
      expect(SyncIndex.fromJsonString(raw).syncPriority, isNull);
    });

    test('unknown syncPriority value degrades to auto (forward-compat)', () {
      final raw = jsonEncode({
        'conversations': {
          'c1': ['m1'],
        },
        'assistantIds': ['a1'],
        'syncPriority': 'bogus',
      });
      expect(SyncIndex.fromJsonString(raw).syncPriority, isNull);
    });

    test('resolveSyncPrecedence derives the role-relative direction', () {
      expect(
        resolveSyncPrecedence(null, isInitiator: true),
        ConflictPrecedence.auto,
      );
      expect(
        resolveSyncPrecedence(null, isInitiator: false),
        ConflictPrecedence.auto,
      );
      expect(
        resolveSyncPrecedence(SyncPriority.initiatorWins, isInitiator: true),
        ConflictPrecedence.localWins,
      );
      expect(
        resolveSyncPrecedence(SyncPriority.initiatorWins, isInitiator: false),
        ConflictPrecedence.incomingWins,
      );
      expect(
        resolveSyncPrecedence(SyncPriority.serverWins, isInitiator: true),
        ConflictPrecedence.incomingWins,
      );
      expect(
        resolveSyncPrecedence(SyncPriority.serverWins, isInitiator: false),
        ConflictPrecedence.localWins,
      );
    });
  });
}
