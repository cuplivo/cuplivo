import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/sync/lan_sync_logic.dart';
import 'package:Cuplivo/core/services/sync/lan_sync_models.dart';

void main() {
  group('findForkPoint', () {
    test(
      'returns last common element when lists share a prefix then diverge',
      () {
        final a = ['m1', 'm2', 'm3', 'm4_a'];
        final b = ['m1', 'm2', 'm3', 'm4_b'];
        expect(findForkPoint(a, b), 'm3');
      },
    );

    test('returns null when lists are completely disjoint', () {
      final a = ['m1', 'm2'];
      final b = ['m3', 'm4'];
      expect(findForkPoint(a, b), isNull);
    });

    test('returns null when first list is empty', () {
      expect(findForkPoint([], ['m1']), isNull);
    });

    test('returns null when second list is empty', () {
      expect(findForkPoint(['m1'], []), isNull);
    });

    test('returns last element when lists are identical', () {
      final a = ['m1', 'm2', 'm3'];
      final b = ['m1', 'm2', 'm3'];
      expect(findForkPoint(a, b), 'm3');
    });

    test('returns first element when only first is shared', () {
      final a = ['m1', 'm2_a'];
      final b = ['m1', 'm2_b'];
      expect(findForkPoint(a, b), 'm1');
    });

    test('returns null when both lists are empty', () {
      expect(findForkPoint([], []), isNull);
    });

    test('handles single-element identical lists', () {
      expect(findForkPoint(['m1'], ['m1']), 'm1');
    });

    test('handles single-element disjoint lists', () {
      expect(findForkPoint(['m1'], ['m2']), isNull);
    });
  });

  group('computeConvPlan', () {
    test('classifies as fork when both sides have increments', () {
      final plan = computeConvPlan(
        ConvPlanInput(
          conversationId: 'c1',
          conversationTitle: 'Chat 1',
          initiatorMsgIds: ['m1', 'm2', 'm3_a'],
          serverMsgIds: ['m1', 'm2', 'm3_b'],
        ),
      );
      expect(plan.state, SyncConvState.fork);
      expect(plan.forkPointMessageId, 'm2');
      expect(plan.initiatorIncrementCount, 1);
      expect(plan.serverIncrementCount, 1);
    });

    test('classifies as initiatorOnly when only A has increments', () {
      final plan = computeConvPlan(
        ConvPlanInput(
          conversationId: 'c1',
          initiatorMsgIds: ['m1', 'm2', 'm3'],
          serverMsgIds: ['m1', 'm2'],
        ),
      );
      expect(plan.state, SyncConvState.initiatorOnly);
      expect(plan.forkPointMessageId, 'm2');
      expect(plan.initiatorIncrementCount, 1);
      expect(plan.serverIncrementCount, 0);
    });

    test('classifies as serverOnly when only B has increments', () {
      final plan = computeConvPlan(
        ConvPlanInput(
          conversationId: 'c1',
          initiatorMsgIds: ['m1', 'm2'],
          serverMsgIds: ['m1', 'm2', 'm3'],
        ),
      );
      expect(plan.state, SyncConvState.serverOnly);
      expect(plan.forkPointMessageId, 'm2');
      expect(plan.initiatorIncrementCount, 0);
      expect(plan.serverIncrementCount, 1);
    });

    test('classifies as identical when both sides match exactly', () {
      final plan = computeConvPlan(
        ConvPlanInput(
          conversationId: 'c1',
          initiatorMsgIds: ['m1', 'm2', 'm3'],
          serverMsgIds: ['m1', 'm2', 'm3'],
        ),
      );
      expect(plan.state, SyncConvState.identical);
      expect(plan.forkPointMessageId, 'm3');
      expect(plan.initiatorIncrementCount, 0);
      expect(plan.serverIncrementCount, 0);
    });

    test('returns all messages as increment when no fork point exists', () {
      final plan = computeConvPlan(
        ConvPlanInput(
          conversationId: 'c1',
          initiatorMsgIds: ['m1', 'm2'],
          serverMsgIds: ['m3', 'm4'],
        ),
      );
      expect(plan.state, SyncConvState.fork);
      expect(plan.forkPointMessageId, isNull);
      expect(plan.initiatorIncrementCount, 2);
      expect(plan.serverIncrementCount, 2);
    });

    test('handles empty initiator list', () {
      final plan = computeConvPlan(
        ConvPlanInput(
          conversationId: 'c1',
          initiatorMsgIds: [],
          serverMsgIds: ['m1', 'm2'],
        ),
      );
      expect(plan.state, SyncConvState.serverOnly);
      expect(plan.forkPointMessageId, isNull);
      expect(plan.initiatorIncrementCount, 0);
      expect(plan.serverIncrementCount, 2);
    });

    test('handles empty server list', () {
      final plan = computeConvPlan(
        ConvPlanInput(
          conversationId: 'c1',
          initiatorMsgIds: ['m1', 'm2'],
          serverMsgIds: [],
        ),
      );
      expect(plan.state, SyncConvState.initiatorOnly);
      expect(plan.forkPointMessageId, isNull);
      expect(plan.initiatorIncrementCount, 2);
      expect(plan.serverIncrementCount, 0);
    });

    test('preserves conversation title', () {
      final plan = computeConvPlan(
        ConvPlanInput(
          conversationId: 'c1',
          conversationTitle: 'My Chat',
          initiatorMsgIds: ['m1'],
          serverMsgIds: ['m1'],
        ),
      );
      expect(plan.conversationTitle, 'My Chat');
    });

    test('handles null conversation title', () {
      final plan = computeConvPlan(
        ConvPlanInput(
          conversationId: 'c1',
          conversationTitle: null,
          initiatorMsgIds: ['m1'],
          serverMsgIds: ['m1'],
        ),
      );
      expect(plan.conversationTitle, isNull);
    });
  });

  group('computeEarliestSince', () {
    test('returns earliest fork-point timestamp', () {
      final plans = [
        SyncConvPlan(
          conversationId: 'c1',
          state: SyncConvState.fork,
          forkPointMessageId: 'm2',
          initiatorIncrementCount: 1,
          serverIncrementCount: 1,
        ),
        SyncConvPlan(
          conversationId: 'c2',
          state: SyncConvState.initiatorOnly,
          forkPointMessageId: 'm5',
          initiatorIncrementCount: 2,
          serverIncrementCount: 0,
        ),
      ];
      final timestamps = {
        'm2': DateTime(2025, 1, 15),
        'm5': DateTime(2025, 1, 10),
      };
      final since = computeEarliestSince(
        plans,
        (_, forkId) => timestamps[forkId],
      );
      expect(since, DateTime(2025, 1, 10));
    });

    test('returns epoch fallback when all conversations are one-sided', () {
      // No fork points → earliestSince would normally be null.
      // But there are non-identical conversations → fallback to DateTime(2000).
      final plans = [
        SyncConvPlan(
          conversationId: 'c1',
          state: SyncConvState.initiatorOnly,
          forkPointMessageId: null,
          initiatorIncrementCount: 3,
          serverIncrementCount: 0,
        ),
        SyncConvPlan(
          conversationId: 'c2',
          state: SyncConvState.serverOnly,
          forkPointMessageId: null,
          initiatorIncrementCount: 0,
          serverIncrementCount: 5,
        ),
      ];
      final since = computeEarliestSince(plans, (_, __) => null);
      expect(since, DateTime(2000));
    });

    test('returns null when all conversations are identical', () {
      final plans = [
        SyncConvPlan(
          conversationId: 'c1',
          state: SyncConvState.identical,
          forkPointMessageId: 'm3',
          initiatorIncrementCount: 0,
          serverIncrementCount: 0,
        ),
      ];
      final since = computeEarliestSince(plans, (_, __) => null);
      expect(since, isNull);
    });

    test('returns null when plan list is empty', () {
      final since = computeEarliestSince([], (_, __) => null);
      expect(since, isNull);
    });

    test(
      'uses fork point from fork conversation when mixed with one-sided',
      () {
        final plans = [
          SyncConvPlan(
            conversationId: 'c1',
            state: SyncConvState.initiatorOnly,
            forkPointMessageId: null,
            initiatorIncrementCount: 3,
            serverIncrementCount: 0,
          ),
          SyncConvPlan(
            conversationId: 'c2',
            state: SyncConvState.fork,
            forkPointMessageId: 'm2',
            initiatorIncrementCount: 1,
            serverIncrementCount: 1,
          ),
        ];
        final since = computeEarliestSince(
          plans,
          (_, forkId) => forkId == 'm2' ? DateTime(2025, 3, 1) : null,
        );
        expect(since, DateTime(2025, 3, 1));
      },
    );

    test('returns epoch fallback when fork-point timestamp lookup fails', () {
      // Fork point exists but timestamp lookup returns null.
      // There are non-identical conversations → fallback to epoch.
      final plans = [
        SyncConvPlan(
          conversationId: 'c1',
          state: SyncConvState.fork,
          forkPointMessageId: 'm2',
          initiatorIncrementCount: 1,
          serverIncrementCount: 1,
        ),
      ];
      final since = computeEarliestSince(plans, (_, __) => null);
      expect(since, DateTime(2000));
    });
  });

  group('SyncIndex serialization', () {
    test('round-trips through JSON', () {
      final original = SyncIndex(
        conversations: {
          'c1': ['m1', 'm2', 'm3'],
          'c2': ['m4'],
        },
        assistantIds: ['a1', 'a2'],
      );
      final jsonStr = original.toJsonString();
      final restored = SyncIndex.fromJsonString(jsonStr);
      expect(restored.conversations, original.conversations);
      expect(restored.assistantIds, original.assistantIds);
    });

    test('handles empty conversations and assistants', () {
      final original = SyncIndex(conversations: {}, assistantIds: []);
      final jsonStr = original.toJsonString();
      final restored = SyncIndex.fromJsonString(jsonStr);
      expect(restored.conversations, isEmpty);
      expect(restored.assistantIds, isEmpty);
    });

    test('handles empty message lists in conversations', () {
      final original = SyncIndex(
        conversations: {'c1': []},
        assistantIds: ['a1'],
      );
      final jsonStr = original.toJsonString();
      final restored = SyncIndex.fromJsonString(jsonStr);
      expect(restored.conversations['c1'], isEmpty);
    });
  });

  group('SyncPlan serialization', () {
    test('round-trips with non-null since', () {
      final original = SyncPlan(
        conversations: [
          SyncConvPlan(
            conversationId: 'c1',
            conversationTitle: 'Chat 1',
            state: SyncConvState.fork,
            forkPointMessageId: 'm2',
            initiatorIncrementCount: 1,
            serverIncrementCount: 1,
          ),
        ],
        missingAssistantIds: ['a3'],
        remoteMissingAssistantIds: ['a4'],
        since: DateTime(2025, 1, 15, 10, 30),
      );
      final jsonStr = original.toJsonString();
      final restored = SyncPlan.fromJsonString(jsonStr);
      expect(restored.conversations.length, 1);
      expect(restored.conversations[0].conversationId, 'c1');
      expect(restored.conversations[0].state, SyncConvState.fork);
      expect(restored.conversations[0].forkPointMessageId, 'm2');
      expect(restored.missingAssistantIds, ['a3']);
      expect(restored.remoteMissingAssistantIds, ['a4']);
      expect(restored.since, DateTime(2025, 1, 15, 10, 30));
    });

    test('round-trips with null since', () {
      final original = SyncPlan(
        conversations: [],
        missingAssistantIds: [],
        remoteMissingAssistantIds: [],
        since: null,
      );
      final jsonStr = original.toJsonString();
      final restored = SyncPlan.fromJsonString(jsonStr);
      expect(restored.conversations, isEmpty);
      expect(restored.since, isNull);
    });

    test('round-trips with null conversationTitle', () {
      final original = SyncPlan(
        conversations: [
          SyncConvPlan(
            conversationId: 'c1',
            conversationTitle: null,
            state: SyncConvState.initiatorOnly,
            forkPointMessageId: null,
            initiatorIncrementCount: 5,
            serverIncrementCount: 0,
          ),
        ],
        missingAssistantIds: [],
        remoteMissingAssistantIds: [],
        since: null,
      );
      final jsonStr = original.toJsonString();
      final restored = SyncPlan.fromJsonString(jsonStr);
      expect(restored.conversations[0].conversationTitle, isNull);
      expect(restored.conversations[0].state, SyncConvState.initiatorOnly);
    });

    test('preserves all four SyncConvState values', () {
      for (final state in SyncConvState.values) {
        final original = SyncPlan(
          conversations: [
            SyncConvPlan(
              conversationId: 'c1',
              state: state,
              forkPointMessageId: 'm1',
              initiatorIncrementCount: 1,
              serverIncrementCount: 1,
            ),
          ],
          missingAssistantIds: [],
          remoteMissingAssistantIds: [],
          since: DateTime(2025, 1, 1),
        );
        final jsonStr = original.toJsonString();
        final restored = SyncPlan.fromJsonString(jsonStr);
        expect(
          restored.conversations[0].state,
          state,
          reason: 'Failed for state $state',
        );
      }
    });
  });

  group('SyncPlan convenience getters', () {
    test('counts by state correctly', () {
      final plan = SyncPlan(
        conversations: [
          SyncConvPlan(
            conversationId: 'c1',
            state: SyncConvState.initiatorOnly,
            forkPointMessageId: null,
            initiatorIncrementCount: 3,
            serverIncrementCount: 0,
          ),
          SyncConvPlan(
            conversationId: 'c2',
            state: SyncConvState.initiatorOnly,
            forkPointMessageId: null,
            initiatorIncrementCount: 1,
            serverIncrementCount: 0,
          ),
          SyncConvPlan(
            conversationId: 'c3',
            state: SyncConvState.serverOnly,
            forkPointMessageId: null,
            initiatorIncrementCount: 0,
            serverIncrementCount: 2,
          ),
          SyncConvPlan(
            conversationId: 'c4',
            state: SyncConvState.fork,
            forkPointMessageId: 'm2',
            initiatorIncrementCount: 1,
            serverIncrementCount: 1,
          ),
          SyncConvPlan(
            conversationId: 'c5',
            state: SyncConvState.identical,
            forkPointMessageId: 'm1',
            initiatorIncrementCount: 0,
            serverIncrementCount: 0,
          ),
        ],
        missingAssistantIds: [],
        remoteMissingAssistantIds: [],
        since: null,
      );
      expect(plan.initiatorOnlyCount, 2);
      expect(plan.serverOnlyCount, 1);
      expect(plan.forkCount, 1);
    });
  });

  Map<String, FileManifestEntry> entry(
    String path,
    int mtimeMs, {
    int size = 1,
  }) => {path: FileManifestEntry(size: size, mtimeMs: mtimeMs)};

  group('computeFileDelta', () {
    test('sends paths absent on the peer', () {
      final local = entry('workspaces/x', 1000);
      final delta = computeFileDelta(local, {});
      expect(delta, {'workspaces/x'});
    });

    test('sends strictly-newer mtime, skips equal and older', () {
      final local = entry('upload/a', 2000)
        ..addAll(entry('upload/b', 2000))
        ..addAll(entry('upload/c', 1000));
      final peer = entry('upload/a', 1999)
        ..addAll(entry('upload/b', 2000))
        ..addAll(entry('upload/c', 2000));
      expect(computeFileDelta(local, peer), {'upload/a'});
    });

    test('empty local manifest sends nothing', () {
      expect(
        computeFileDelta({}, {
          'upload/a': const FileManifestEntry(size: 1, mtimeMs: 1000),
        }),
        isEmpty,
      );
    });

    test('equal mtime across peers is treated as synced (no double send)', () {
      // The receiving side's merge is strictly-newer, so an equal-mtime path
      // must not be sent by either side.
      final manifest = entry('workspaces/f', 500);
      expect(computeFileDelta(manifest, manifest), isEmpty);
    });
  });

  group('sumDeltaBytes', () {
    test('sums only the delta paths', () {
      final manifest = entry('upload/a', 1, size: 10)
        ..addAll(entry('upload/b', 1, size: 20))
        ..addAll(entry('upload/c', 1, size: 30));
      expect(sumDeltaBytes(manifest, {'upload/b', 'upload/c'}), 50);
    });

    test('missing path contributes zero', () {
      final manifest = entry('upload/a', 1, size: 10);
      expect(sumDeltaBytes(manifest, {'upload/a', 'nope/x'}), 10);
    });
  });

  group('parseMultipartBytes', () {
    test('parses zip and since fields', () {
      // Build a minimal multipart body:
      // --boundary\r\nContent-Disposition: form-data; name="zip"\r\n\r\n<zip-bytes>\r\n
      // --boundary\r\nContent-Disposition: form-data; name="since"\r\n\r\n2025-01-15T10:30:00.000\r\n
      // --boundary--\r\n
      final boundary = 'testboundary';
      final zipData = [0x50, 0x4B, 0x03, 0x04]; // PK header
      final sinceStr = '2025-01-15T10:30:00.000';

      final body = <int>[];
      body.addAll(utf8.encode('--$boundary\r\n'));
      body.addAll(
        utf8.encode('Content-Disposition: form-data; name="zip"\r\n\r\n'),
      );
      body.addAll(zipData);
      body.addAll(utf8.encode('\r\n'));
      body.addAll(utf8.encode('--$boundary\r\n'));
      body.addAll(
        utf8.encode('Content-Disposition: form-data; name="since"\r\n\r\n'),
      );
      body.addAll(utf8.encode(sinceStr));
      body.addAll(utf8.encode('\r\n'));
      body.addAll(utf8.encode('--$boundary--\r\n'));

      final parts = parseMultipartBytes(body, boundary);
      expect(parts['zip'], zipData);
      expect(utf8.decode(parts['since']!), sinceStr);
    });

    test('parses zip-only (no since field)', () {
      final boundary = 'testboundary';
      final zipData = [0x50, 0x4B, 0x03, 0x04];

      final body = <int>[];
      body.addAll(utf8.encode('--$boundary\r\n'));
      body.addAll(
        utf8.encode('Content-Disposition: form-data; name="zip"\r\n\r\n'),
      );
      body.addAll(zipData);
      body.addAll(utf8.encode('\r\n'));
      body.addAll(utf8.encode('--$boundary--\r\n'));

      final parts = parseMultipartBytes(body, boundary);
      expect(parts['zip'], zipData);
      expect(parts.containsKey('since'), isFalse);
    });

    test('parses since-only (no zip field)', () {
      final boundary = 'testboundary';
      final sinceStr = '2025-01-15T10:30:00.000';

      final body = <int>[];
      body.addAll(utf8.encode('--$boundary\r\n'));
      body.addAll(
        utf8.encode('Content-Disposition: form-data; name="since"\r\n\r\n'),
      );
      body.addAll(utf8.encode(sinceStr));
      body.addAll(utf8.encode('\r\n'));
      body.addAll(utf8.encode('--$boundary--\r\n'));

      final parts = parseMultipartBytes(body, boundary);
      expect(parts.containsKey('zip'), isFalse);
      expect(utf8.decode(parts['since']!), sinceStr);
    });

    test('returns empty map for empty body', () {
      final parts = parseMultipartBytes([], 'testboundary');
      expect(parts, isEmpty);
    });

    test('handles binary data with CR/LF bytes in zip body', () {
      // ZIP files can contain 0x0D and 0x0A bytes naturally.
      // The parser must not strip them from the middle of the body,
      // only from the trailing \r\n before the next boundary.
      final boundary = 'testboundary';
      final zipData = [0x50, 0x4B, 0x0D, 0x0A, 0x03, 0x04, 0x00, 0x00];

      final body = <int>[];
      body.addAll(utf8.encode('--$boundary\r\n'));
      body.addAll(
        utf8.encode('Content-Disposition: form-data; name="zip"\r\n\r\n'),
      );
      body.addAll(zipData);
      body.addAll(utf8.encode('\r\n'));
      body.addAll(utf8.encode('--$boundary--\r\n'));

      final parts = parseMultipartBytes(body, boundary);
      expect(parts['zip'], zipData);
    });

    test('parses field with empty body', () {
      final boundary = 'testboundary';

      final body = <int>[];
      body.addAll(utf8.encode('--$boundary\r\n'));
      body.addAll(
        utf8.encode('Content-Disposition: form-data; name="empty"\r\n\r\n'),
      );
      body.addAll(utf8.encode('\r\n'));
      body.addAll(utf8.encode('--$boundary--\r\n'));

      final parts = parseMultipartBytes(body, boundary);
      expect(parts['empty'], isEmpty);
    });

    test('preserves trailing 0x0D (CR) in zip body', () {
      // A zip file whose last byte is 0x0D must not be stripped.
      final boundary = 'testboundary';
      final zipData = [0x50, 0x4B, 0x03, 0x04, 0x0D];

      final body = <int>[];
      body.addAll(utf8.encode('--$boundary\r\n'));
      body.addAll(
        utf8.encode('Content-Disposition: form-data; name="zip"\r\n\r\n'),
      );
      body.addAll(zipData);
      body.addAll(utf8.encode('\r\n'));
      body.addAll(utf8.encode('--$boundary--\r\n'));

      final parts = parseMultipartBytes(body, boundary);
      expect(parts['zip'], zipData);
    });

    test('preserves trailing 0x0A (LF) in zip body', () {
      // A zip file whose last byte is 0x0A must not be stripped.
      final boundary = 'testboundary';
      final zipData = [0x50, 0x4B, 0x03, 0x04, 0x0A];

      final body = <int>[];
      body.addAll(utf8.encode('--$boundary\r\n'));
      body.addAll(
        utf8.encode('Content-Disposition: form-data; name="zip"\r\n\r\n'),
      );
      body.addAll(zipData);
      body.addAll(utf8.encode('\r\n'));
      body.addAll(utf8.encode('--$boundary--\r\n'));

      final parts = parseMultipartBytes(body, boundary);
      expect(parts['zip'], zipData);
    });

    test('preserves trailing 0x0D 0x0A 0x0D in zip body', () {
      // Last 3 bytes: CR LF CR — the parser should strip only the \r\n
      // transport padding, leaving the final CR as part of the body.
      final boundary = 'testboundary';
      final zipData = [0x50, 0x4B, 0x03, 0x04, 0x0D, 0x0A, 0x0D];

      final body = <int>[];
      body.addAll(utf8.encode('--$boundary\r\n'));
      body.addAll(
        utf8.encode('Content-Disposition: form-data; name="zip"\r\n\r\n'),
      );
      body.addAll(zipData);
      body.addAll(utf8.encode('\r\n'));
      body.addAll(utf8.encode('--$boundary--\r\n'));

      final parts = parseMultipartBytes(body, boundary);
      expect(parts['zip'], zipData);
    });
  });

  group('conversationMetadataConflict (issue #615 category D)', () {
    Map<String, dynamic> row({
      String title = 'Chat',
      bool isPinned = false,
      Map<String, int> versionSelections = const {},
      List<String> chatSuggestions = const [],
    }) => {
      'id': 'c1',
      'title': title,
      'createdAt': '2025-01-01T00:00:00.000',
      'updatedAt': '2025-06-01T00:00:00.000',
      'messageIds': <String>['m1', 'm2'],
      'isPinned': isPinned,
      'versionSelections': versionSelections,
      'chatSuggestions': chatSuggestions,
    };

    test('identical metadata (and volatile fields) is NOT a conflict', () {
      expect(conversationMetadataConflict(row(), row()), isFalse);
    });

    test('title difference is a conflict', () {
      expect(conversationMetadataConflict(row(), row(title: 'Other')), isTrue);
    });

    test('isPinned difference is a conflict', () {
      expect(conversationMetadataConflict(row(), row(isPinned: true)), isTrue);
    });

    test('nullable summary presence is a conflict', () {
      final a = row()..['summary'] = 'short story';
      expect(conversationMetadataConflict(a, row()), isTrue);
    });

    test('nested map/list values compare by content, not identity', () {
      expect(
        conversationMetadataConflict(
          row(versionSelections: {'g1': 2}),
          row(versionSelections: {'g1': 2}),
        ),
        isFalse,
      );
      expect(
        conversationMetadataConflict(
          row(chatSuggestions: ['a', 'b']),
          row(chatSuggestions: ['a', 'b']),
        ),
        isFalse,
      );
      expect(
        conversationMetadataConflict(
          row(chatSuggestions: ['a', 'b']),
          row(chatSuggestions: ['a', 'c']),
        ),
        isTrue,
      );
    });

    test('id/createdAt/updatedAt/messageIds differences alone are NOT', () {
      final a = row()..['messageIds'] = ['m1', 'm2', 'mine'];
      final b = row()..['updatedAt'] = '2025-07-01T00:00:00.000';
      expect(conversationMetadataConflict(a, b), isFalse);
    });

    test('missing key on one side is a conflict', () {
      final a = row()..remove('isPinned');
      expect(conversationMetadataConflict(a, row()), isTrue);
    });
  });

  group('conversationIsMetadataOnlyConflict (issue #615 category D)', () {
    SyncConvPlan identicalPlan() => const SyncConvPlan(
      conversationId: 'c1',
      state: SyncConvState.identical,
      initiatorIncrementCount: 0,
      serverIncrementCount: 0,
    );
    SyncConvPlan forkPlan() => const SyncConvPlan(
      conversationId: 'c1',
      state: SyncConvState.fork,
      initiatorIncrementCount: 1,
      serverIncrementCount: 0,
      forkPointMessageId: 'm1',
    );
    Map<String, dynamic> row({String title = 'Chat'}) => {
      'id': 'c1',
      'title': title,
      'createdAt': '2025-01-01T00:00:00.000',
      'updatedAt': '2025-06-01T00:00:00.000',
      'messageIds': <String>['m1'],
      'isPinned': false,
    };

    test('identical messages + differing rows + confirmed => conflict', () {
      expect(
        conversationIsMetadataOnlyConflict(
          plan: identicalPlan(),
          theirRowJson: row(title: 'Phone'),
          myRowJson: row(title: 'PC'),
          hasConfirmedDirection: true,
        ),
        isTrue,
      );
    });

    test('identical rows are never a conflict', () {
      expect(
        conversationIsMetadataOnlyConflict(
          plan: identicalPlan(),
          theirRowJson: row(),
          myRowJson: row(),
          hasConfirmedDirection: true,
        ),
        isFalse,
      );
    });

    test('auto sessions never flag (payload shape stays byte-identical)', () {
      expect(
        conversationIsMetadataOnlyConflict(
          plan: identicalPlan(),
          theirRowJson: row(title: 'Phone'),
          myRowJson: row(title: 'PC'),
          hasConfirmedDirection: false,
        ),
        isFalse,
      );
    });

    test('fork rows ride their delta; no metadata-only flag needed', () {
      expect(
        conversationIsMetadataOnlyConflict(
          plan: forkPlan(),
          theirRowJson: row(title: 'Phone'),
          myRowJson: row(title: 'PC'),
          hasConfirmedDirection: true,
        ),
        isFalse,
      );
    });

    test('old peer without rows degrades to no conflict', () {
      expect(
        conversationIsMetadataOnlyConflict(
          plan: identicalPlan(),
          theirRowJson: null,
          myRowJson: row(title: 'PC'),
          hasConfirmedDirection: true,
        ),
        isFalse,
      );
    });

    test('group conversations are excluded (group payload owns metadata)', () {
      expect(
        conversationIsMetadataOnlyConflict(
          plan: identicalPlan(),
          theirRowJson: row(),
          myRowJson: row()..['conversationKind'] = 'group',
          hasConfirmedDirection: true,
        ),
        isFalse,
      );
    });
  });
}
