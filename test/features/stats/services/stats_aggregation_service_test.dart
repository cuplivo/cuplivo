import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/features/stats/models/stats_models.dart';
import 'package:Cuplivo/features/stats/services/stats_aggregation_service.dart';

void main() {
  group('StatsAggregationService', () {
    final now = DateTime(2026, 5, 3, 12);

    Conversation conversation(
      String id, {
      required String title,
      required DateTime createdAt,
      String? assistantId,
      List<String>? messageIds,
    }) {
      return Conversation(
        id: id,
        title: title,
        createdAt: createdAt,
        updatedAt: createdAt,
        assistantId: assistantId,
        messageIds: messageIds ?? const [],
      );
    }

    ChatMessage message(
      String id, {
      required String conversationId,
      required DateTime timestamp,
      String role = 'assistant',
      String? modelId,
      String? providerId,
      int? totalTokens,
      int? contextTokens,
      int? promptTokens,
      int? completionTokens,
      int? cachedTokens,
    }) {
      return ChatMessage(
        id: id,
        role: role,
        content: 'message $id',
        timestamp: timestamp,
        conversationId: conversationId,
        modelId: modelId,
        providerId: providerId,
        totalTokens: totalTokens,
        contextTokens: contextTokens,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        cachedTokens: cachedTokens,
      );
    }

    test(
      'aggregates all-time totals, heatmap, rankings, and provider trend',
      () {
        final conversations = [
          conversation(
            'c1',
            title: 'Alpha topic',
            assistantId: 'a1',
            createdAt: now.subtract(const Duration(days: 4)),
            messageIds: ['m1', 'm2', 'm3'],
          ),
          conversation(
            'c2',
            title: 'Beta topic',
            assistantId: 'a2',
            createdAt: now.subtract(const Duration(days: 40)),
            messageIds: ['m4', 'm5'],
          ),
        ];
        final messagesByConversation = {
          'c1': [
            message(
              'm1',
              conversationId: 'c1',
              timestamp: now.subtract(const Duration(days: 2)),
              role: 'user',
              modelId: 'gpt-5.4-mini',
              providerId: 'openai',
              promptTokens: 10,
            ),
            message(
              'm2',
              conversationId: 'c1',
              timestamp: now.subtract(const Duration(days: 2)),
              modelId: 'gpt-5.4-mini',
              providerId: 'openai',
              completionTokens: 20,
              cachedTokens: 3,
            ),
            message(
              'm3',
              conversationId: 'c1',
              timestamp: now.subtract(const Duration(days: 1)),
              modelId: 'gemini-3-pro-preview',
              providerId: 'google',
              promptTokens: 7,
              completionTokens: 11,
            ),
          ],
          'c2': [
            message(
              'm4',
              conversationId: 'c2',
              timestamp: now.subtract(const Duration(days: 40)),
              modelId: 'mimo-v2-omni',
              providerId: 'mimo',
              promptTokens: 5,
              completionTokens: 9,
              cachedTokens: 1,
            ),
            message(
              'm5',
              conversationId: 'c2',
              timestamp: now.subtract(const Duration(days: 40)),
              role: 'user',
            ),
          ],
        };

        final snapshot = StatsAggregationService.buildSnapshot(
          now: now,
          range: StatsDateRange.allTime(now),
          conversations: conversations,
          messagesByConversation: messagesByConversation,
          launchCount: 12,
          unknownProviderLabel: 'Unknown provider',
          unknownTopicLabel: 'Untitled topic',
          assistantNames: const {'a1': 'Default Assistant', 'a2': 'Research'},
          providerNames: const {
            'openai': 'OpenAI',
            'google': 'Gemini',
            'mimo': 'MiMo',
          },
        );

        expect(snapshot.summary.totalConversations, 2);
        expect(snapshot.summary.totalMessages, 5);
        expect(snapshot.summary.inputTokens, 22);
        expect(snapshot.summary.outputTokens, 40);
        expect(snapshot.summary.cachedTokens, 4);
        expect(snapshot.summary.launchCount, 12);
        expect(snapshot.modelRank.map((e) => (e.id, e.value)).toList(), [
          ('gpt-5.4-mini', 2),
          ('gemini-3-pro-preview', 1),
          ('mimo-v2-omni', 1),
        ]);
        expect(snapshot.modelRank.map((e) => e.providerId).toList(), [
          'openai',
          'google',
          'mimo',
        ]);
        expect(snapshot.assistantRank.map((e) => (e.label, e.value)).toList(), [
          ('Default Assistant', 1),
          ('Research', 1),
        ]);
        expect(snapshot.topicRank.map((e) => (e.label, e.value)).toList(), [
          ('Alpha topic', 3),
          ('Beta topic', 2),
        ]);

        final twoDaysAgo = DateTime(2026, 5, 1);
        final heatCell = snapshot.heatmap.firstWhere(
          (e) => e.date == twoDaysAgo,
        );
        expect(heatCell.count, 2);

        final trendDay = snapshot.trend.firstWhere((e) => e.date == twoDaysAgo);
        expect(trendDay.providerTokens['OpenAI']!.inputTokens, 10);
        expect(trendDay.providerTokens['OpenAI']!.outputTokens, 20);
        expect(trendDay.providerTokens['OpenAI']!.cachedTokens, 3);
      },
    );

    test(
      'filters counters and rankings while all-time trend stays last 30 days',
      () {
        final conversations = [
          conversation(
            'recent',
            title: 'Recent',
            assistantId: 'a1',
            createdAt: now.subtract(const Duration(days: 1)),
            messageIds: ['recent-message'],
          ),
          conversation(
            'old',
            title: 'Old',
            assistantId: 'a2',
            createdAt: now.subtract(const Duration(days: 80)),
            messageIds: ['old-message'],
          ),
        ];
        final messagesByConversation = {
          'recent': [
            message(
              'recent-message',
              conversationId: 'recent',
              timestamp: now.subtract(const Duration(days: 1)),
              modelId: 'recent-model',
              providerId: 'recent-provider',
              promptTokens: 4,
              completionTokens: 6,
            ),
          ],
          'old': [
            message(
              'old-message',
              conversationId: 'old',
              timestamp: now.subtract(const Duration(days: 80)),
              modelId: 'old-model',
              providerId: 'old-provider',
              promptTokens: 100,
              completionTokens: 200,
            ),
          ],
        };

        final last30 = StatsAggregationService.buildSnapshot(
          now: now,
          range: StatsDateRange.last30Days(now),
          conversations: conversations,
          messagesByConversation: messagesByConversation,
          launchCount: 1,
          unknownProviderLabel: 'Unknown provider',
          unknownTopicLabel: 'Untitled topic',
        );

        expect(last30.summary.totalConversations, 1);
        expect(last30.summary.totalMessages, 1);
        expect(last30.summary.inputTokens, 4);
        expect(last30.modelRank.single.id, 'recent-model');

        final allTime = StatsAggregationService.buildSnapshot(
          now: now,
          range: StatsDateRange.allTime(now),
          conversations: conversations,
          messagesByConversation: messagesByConversation,
          launchCount: 1,
          unknownProviderLabel: 'Unknown provider',
          unknownTopicLabel: 'Untitled topic',
        );

        expect(allTime.summary.totalConversations, 2);
        expect(allTime.summary.inputTokens, 104);
        expect(
          allTime.trend.any((d) => d.date == DateTime(2026, 2, 12)),
          false,
        );
      },
    );

    test('keeps heatmap and trend dates aligned across DST boundaries', () {
      final dstNow = DateTime(2026, 3, 10, 12);
      final dstDay = DateTime(2026, 3, 8, 9);
      final conversations = [
        conversation(
          'dst',
          title: 'DST topic',
          createdAt: dstDay,
          messageIds: ['dst-message'],
        ),
      ];
      final messagesByConversation = {
        'dst': [
          message(
            'dst-message',
            conversationId: 'dst',
            timestamp: dstDay,
            providerId: 'openai',
            promptTokens: 3,
            completionTokens: 5,
          ),
        ],
      };

      final snapshot = StatsAggregationService.buildSnapshot(
        now: dstNow,
        range: StatsDateRange.last30Days(dstNow),
        conversations: conversations,
        messagesByConversation: messagesByConversation,
        launchCount: 1,
        unknownProviderLabel: 'Unknown provider',
        unknownTopicLabel: 'Untitled topic',
        providerNames: const {'openai': 'OpenAI'},
      );

      expect(snapshot.range.start, DateTime(2026, 2, 9));
      expect(snapshot.heatmap.length, 365);
      expect(
        snapshot.heatmap.map((day) => day.date),
        contains(DateTime(2026, 3, 8)),
      );
      expect(
        snapshot.heatmap.where(
          (day) => day.date.hour != 0 || day.date.minute != 0,
        ),
        isEmpty,
      );
      expect(
        snapshot.heatmap
            .singleWhere((day) => day.date == DateTime(2026, 3, 8))
            .count,
        1,
      );

      final trendDay = snapshot.trend.singleWhere(
        (day) => day.date == DateTime(2026, 3, 8),
      );
      expect(trendDay.providerTokens['OpenAI']!.inputTokens, 3);
      expect(trendDay.providerTokens['OpenAI']!.outputTokens, 5);
    });

    test('keeps all-time trend dates aligned across DST boundaries', () {
      final dstNow = DateTime(2026, 3, 10, 12);
      final dstDay = DateTime(2026, 3, 8, 9);
      final conversations = [
        conversation(
          'dst',
          title: 'DST topic',
          createdAt: dstDay,
          messageIds: ['dst-message'],
        ),
      ];
      final messagesByConversation = {
        'dst': [
          message(
            'dst-message',
            conversationId: 'dst',
            timestamp: dstDay,
            providerId: 'openai',
            promptTokens: 3,
          ),
        ],
      };

      final snapshot = StatsAggregationService.buildSnapshot(
        now: dstNow,
        range: StatsDateRange.allTime(dstNow),
        conversations: conversations,
        messagesByConversation: messagesByConversation,
        launchCount: 1,
        unknownProviderLabel: 'Unknown provider',
        unknownTopicLabel: 'Untitled topic',
        providerNames: const {'openai': 'OpenAI'},
      );

      final trendDay = snapshot.trend.singleWhere(
        (day) => day.date == DateTime(2026, 3, 8),
      );
      expect(trendDay.providerTokens['OpenAI']!.inputTokens, 3);
      expect(
        snapshot.trend.where(
          (day) => day.date.hour != 0 || day.date.minute != 0,
        ),
        isEmpty,
      );
    });

    test('excludes conversations for assistants that no longer exist', () {
      final conversations = [
        conversation(
          'active',
          title: 'Active topic',
          assistantId: 'a1',
          createdAt: now.subtract(const Duration(days: 1)),
          messageIds: ['m-active'],
        ),
        conversation(
          'deleted',
          title: 'Deleted topic',
          assistantId: '2d111bb3-de7b-4ad6-903d-e09cefd7c933',
          createdAt: now.subtract(const Duration(days: 1)),
          messageIds: ['m-deleted'],
        ),
      ];

      // Both conversations hold in-range activity, so both count towards
      // totalConversations; only the surviving assistant is ranked.
      final messagesByConversation = {
        'active': [
          message(
            'm-active',
            conversationId: 'active',
            timestamp: now.subtract(const Duration(hours: 2)),
            modelId: 'gpt-4o',
            providerId: 'openai',
            promptTokens: 10,
          ),
        ],
        'deleted': [
          message(
            'm-deleted',
            conversationId: 'deleted',
            timestamp: now.subtract(const Duration(hours: 2)),
            modelId: 'gpt-4o',
            providerId: 'openai',
            promptTokens: 10,
          ),
        ],
      };

      final snapshot = StatsAggregationService.buildSnapshot(
        now: now,
        range: StatsDateRange.allTime(now),
        conversations: conversations,
        messagesByConversation: messagesByConversation,
        launchCount: 1,
        unknownProviderLabel: 'Unknown provider',
        unknownTopicLabel: 'Untitled topic',
        assistantNames: const {'a1': 'Active Assistant'},
        existingAssistantIds: const {'a1'},
      );

      expect(snapshot.summary.totalConversations, 2);
      expect(snapshot.assistantRank.map((e) => e.id).toList(), ['a1']);
      expect(snapshot.assistantRank.single.label, 'Active Assistant');
    });

    test(
      'sums consumed fields exactly and ignores contextTokens (dual semantics)',
      () {
        // A multi-round tool-call message: promptTokens/completionTokens hold
        // the SUM across rounds (consumed), contextTokens holds the LAST
        // round's total (context). Stats must aggregate the consumed values
        // and must not double-count contextTokens.
        final conversations = [
          conversation(
            'c-tool',
            title: 'Tool topic',
            createdAt: now.subtract(const Duration(days: 1)),
            messageIds: ['m-tool'],
          ),
        ];
        final messagesByConversation = {
          'c-tool': [
            message(
              'm-tool',
              conversationId: 'c-tool',
              timestamp: now.subtract(const Duration(days: 1)),
              providerId: 'openai',
              totalTokens: 3020,
              promptTokens: 2200,
              completionTokens: 820,
              cachedTokens: 700,
              contextTokens: 1500,
            ),
          ],
        };

        final snapshot = StatsAggregationService.buildSnapshot(
          now: now,
          range: StatsDateRange.allTime(now),
          conversations: conversations,
          messagesByConversation: messagesByConversation,
          launchCount: 1,
          unknownProviderLabel: 'Unknown provider',
          unknownTopicLabel: 'Untitled topic',
          providerNames: const {'openai': 'OpenAI'},
        );

        expect(snapshot.summary.inputTokens, 2200);
        expect(snapshot.summary.outputTokens, 820);
        expect(snapshot.summary.cachedTokens, 700);

        final trendDay = snapshot.trend.firstWhere(
          (day) => day.date == DateTime(2026, 5, 2),
        );
        final bucket = trendDay.providerTokens['OpenAI']!;
        expect(bucket.inputTokens, 2200);
        expect(bucket.outputTokens, 820);
        expect(bucket.cachedTokens, 700);
        // totalTokens of the bucket is derived from the consumed split
        // fields, not from the stored contextTokens.
        expect(bucket.totalTokens, 3020);
      },
    );

    test('uses total tokens as trend fallback for legacy messages', () {
      final conversations = [
        conversation(
          'legacy',
          title: 'Legacy topic',
          createdAt: now.subtract(const Duration(days: 1)),
          messageIds: ['legacy-message'],
        ),
      ];
      final messagesByConversation = {
        'legacy': [
          message(
            'legacy-message',
            conversationId: 'legacy',
            timestamp: now.subtract(const Duration(days: 1)),
            providerId: 'openai',
            totalTokens: 42,
          ),
        ],
      };

      final snapshot = StatsAggregationService.buildSnapshot(
        now: now,
        range: StatsDateRange.allTime(now),
        conversations: conversations,
        messagesByConversation: messagesByConversation,
        launchCount: 1,
        unknownProviderLabel: 'Unknown provider',
        unknownTopicLabel: 'Untitled topic',
        providerNames: const {'openai': 'OpenAI'},
      );

      final trendDay = snapshot.trend.firstWhere(
        (day) => day.date == DateTime(2026, 5, 2),
      );
      expect(trendDay.providerTokens['OpenAI']!.totalTokens, 42);
    });

    test('does not create unknown provider trend rows without token data', () {
      final conversations = [
        conversation(
          'empty-provider',
          title: 'Empty provider topic',
          createdAt: now.subtract(const Duration(days: 1)),
          messageIds: ['empty-provider-message'],
        ),
      ];
      final messagesByConversation = {
        'empty-provider': [
          message(
            'empty-provider-message',
            conversationId: 'empty-provider',
            timestamp: now.subtract(const Duration(days: 1)),
          ),
        ],
      };

      final snapshot = StatsAggregationService.buildSnapshot(
        now: now,
        range: StatsDateRange.allTime(now),
        conversations: conversations,
        messagesByConversation: messagesByConversation,
        launchCount: 1,
        unknownProviderLabel: 'Unknown provider',
        unknownTopicLabel: 'Untitled topic',
      );

      final trendDay = snapshot.trend.firstWhere(
        (day) => day.date == DateTime(2026, 5, 2),
      );
      expect(trendDay.providerTokens, isEmpty);
    });

    group('filters', () {
      final conversations = [
        conversation(
          'c1',
          title: 'Alpha topic',
          assistantId: 'a1',
          createdAt: now.subtract(const Duration(days: 1)),
          messageIds: ['m1', 'm2', 'm3'],
        ),
        conversation(
          'c2',
          title: 'Beta topic',
          assistantId: 'a2',
          createdAt: now.subtract(const Duration(days: 2)),
          messageIds: ['m4'],
        ),
      ];
      final messagesByConversation = {
        'c1': [
          message(
            'm1',
            conversationId: 'c1',
            timestamp: now.subtract(const Duration(hours: 3)),
            modelId: 'gpt-4o',
            providerId: 'openai',
            promptTokens: 100,
            completionTokens: 50,
            cachedTokens: 10,
          ),
          message(
            'm2',
            conversationId: 'c1',
            timestamp: now.subtract(const Duration(hours: 2)),
            modelId: 'claude-3',
            providerId: 'anthropic',
            promptTokens: 200,
            completionTokens: 80,
            cachedTokens: 0,
          ),
          message(
            'm3',
            conversationId: 'c1',
            timestamp: now.subtract(const Duration(hours: 1)),
            modelId: 'gpt-4o',
            providerId: 'openai',
            promptTokens: 300,
            completionTokens: 120,
            cachedTokens: 20,
          ),
          message(
            'm5',
            conversationId: 'c1',
            timestamp: now.subtract(const Duration(minutes: 45)),
            modelId: 'o4-mini',
            providerId: 'openai',
            promptTokens: 25,
            completionTokens: 5,
            cachedTokens: 0,
          ),
        ],
        'c2': [
          message(
            'm4',
            conversationId: 'c2',
            timestamp: now.subtract(const Duration(minutes: 30)),
            modelId: 'gpt-4o',
            providerId: 'openai',
            promptTokens: 50,
            completionTokens: 10,
            cachedTokens: 0,
          ),
        ],
      };

      StatsSnapshot build(
        StatsFilter filter, {
        Map<String, String> providerNames = const {},
      }) {
        return StatsAggregationService.buildSnapshot(
          now: now,
          range: StatsDateRange.allTime(now),
          conversations: conversations,
          messagesByConversation: messagesByConversation,
          launchCount: 0,
          unknownProviderLabel: 'Unknown provider',
          unknownTopicLabel: 'Untitled topic',
          providerNames: providerNames,
          filter: filter,
        );
      }

      test('filters by model ids', () {
        final snapshot = build(const StatsFilter(modelIds: {'claude-3'}));

        expect(snapshot.summary.totalMessages, 1);
        expect(snapshot.summary.inputTokens, 200);
        expect(snapshot.summary.outputTokens, 80);
        expect(snapshot.summary.cachedTokens, 0);
        expect(snapshot.summary.totalConversations, 1);
        expect(snapshot.modelRank.single.id, 'claude-3');
        expect(snapshot.topicRank.single.id, 'c1');
        // Heatmap only counts the matching message.
        final matchingDay = snapshot.heatmap.firstWhere(
          (day) => day.date == DateTime(2026, 5, 3),
        );
        expect(matchingDay.count, 1);
      });

      test('provider-header select-all filters via a multi-model OR set', () {
        // After removing the providerIds dimension, checking a provider
        // header in the sheet equals selecting ALL of its models. This set
        // must include every openai model (gpt-4o + o4-mini) and exclude the
        // anthropic one — the closest thing left to provider-level filtering.
        final snapshot = build(
          const StatsFilter(modelIds: {'gpt-4o', 'o4-mini'}),
        );

        expect(snapshot.summary.totalMessages, 4);
        expect(snapshot.summary.inputTokens, 475);
        expect(snapshot.summary.outputTokens, 185);
        expect(snapshot.modelRank.map((e) => e.id), ['gpt-4o', 'o4-mini']);
      });

      test('filters by assistant ids (conversation based)', () {
        final snapshot = build(const StatsFilter(assistantIds: {'a2'}));

        expect(snapshot.summary.totalMessages, 1);
        expect(snapshot.summary.totalConversations, 1);
        expect(snapshot.assistantRank.single.id, 'a2');
        expect(snapshot.topicRank.single.id, 'c2');
      });

      test('filters by topic ids (conversation based)', () {
        final snapshot = build(const StatsFilter(topicIds: {'c1'}));

        expect(snapshot.summary.totalMessages, 4);
        expect(snapshot.summary.totalConversations, 1);
        expect(snapshot.topicRank.single.id, 'c1');
        expect(snapshot.assistantRank.single.id, 'a1');
      });

      test('combines dimensions with AND semantics', () {
        final snapshot = build(
          const StatsFilter(modelIds: {'gpt-4o'}, assistantIds: {'a2'}),
        );

        expect(snapshot.summary.totalMessages, 1);
        expect(snapshot.summary.inputTokens, 50);
        expect(snapshot.modelRank.single.id, 'gpt-4o');
      });

      test('empty result keeps all metrics at zero', () {
        final snapshot = build(const StatsFilter(modelIds: {'no-such-model'}));

        expect(snapshot.summary.totalMessages, 0);
        expect(snapshot.summary.inputTokens, 0);
        expect(snapshot.summary.totalConversations, 0);
        expect(snapshot.modelRank, isEmpty);
        expect(snapshot.assistantRank, isEmpty);
        expect(snapshot.topicRank, isEmpty);
      });

      test(
        'trend honors the filter and buckets by resolved provider label',
        () {
          final snapshot = build(
            const StatsFilter(modelIds: {'claude-3'}),
            providerNames: const {'anthropic': 'Anthropic', 'openai': 'OpenAI'},
          );

          final matchingDay = snapshot.trend.firstWhere(
            (day) => day.date == DateTime(2026, 5, 3),
          );
          // Trend buckets by display label; the filter must exclude OpenAI.
          expect(matchingDay.providerTokens.keys, contains('Anthropic'));
          expect(matchingDay.providerTokens.keys, isNot(contains('OpenAI')));
          expect(matchingDay.providerTokens['Anthropic']!.inputTokens, 200);
        },
      );

      test('inactive filter matches everything', () {
        final snapshot = build(const StatsFilter());

        expect(snapshot.summary.totalMessages, 5);
        expect(snapshot.summary.totalConversations, 2);
        expect(snapshot.modelRank, hasLength(3));
      });

      test('StatsFilter has value equality', () {
        const a = StatsFilter(modelIds: {'m1', 'm2'}, assistantIds: {'x'});
        const b = StatsFilter(modelIds: {'m2', 'm1'}, assistantIds: {'x'});
        const c = StatsFilter(modelIds: {'m1'}, assistantIds: {'x'});

        expect(a, equals(b));
        expect(a.hashCode, b.hashCode);
        expect(a, isNot(equals(c)));
      });

      test('StatsFilter.copyWith clears a dimension only via an empty set', () {
        const a = StatsFilter(modelIds: {'m1'}, topicIds: {'t1'});

        // null keeps the current value...
        expect(a.copyWith(modelIds: null).modelIds, {'m1'});
        // ...while an explicit empty set clears it.
        expect(a.copyWith(modelIds: const {}).modelIds, isEmpty);
        expect(a.copyWith(modelIds: const {}).isActive, isTrue);
        expect(
          a.copyWith(modelIds: const {}, topicIds: const {}).isActive,
          isFalse,
        );
      });

      test('blank model ids are excluded by an active model filter', () {
        final withBlank = [
          message(
            'm-blank',
            conversationId: 'c1',
            timestamp: now.subtract(const Duration(hours: 1)),
            modelId: '  ',
            promptTokens: 999,
          ),
        ];
        final snapshot = StatsAggregationService.buildSnapshot(
          now: now,
          range: StatsDateRange.allTime(now),
          conversations: conversations,
          messagesByConversation: {'c1': withBlank, 'c2': const []},
          launchCount: 0,
          unknownProviderLabel: 'Unknown provider',
          unknownTopicLabel: 'Untitled topic',
          filter: const StatsFilter(modelIds: {'gpt-4o'}),
        );

        expect(snapshot.summary.totalMessages, 0);
        expect(snapshot.summary.inputTokens, 0);
      });

      test('unfiltered conversation metrics count activity, not creation', () {
        // Pins the default-view semantics change that came with filtering:
        // totalConversations / assistantRank reflect conversations holding
        // at least one message inside the range — an empty conversation
        // created in range no longer counts.
        final conversationsOnly = [
          conversation(
            'ghost',
            title: 'Empty ghost topic',
            assistantId: 'a1',
            createdAt: now.subtract(const Duration(hours: 1)),
          ),
        ];
        final snapshot = StatsAggregationService.buildSnapshot(
          now: now,
          range: StatsDateRange.allTime(now),
          conversations: conversationsOnly,
          messagesByConversation: const {},
          launchCount: 0,
          unknownProviderLabel: 'Unknown provider',
          unknownTopicLabel: 'Untitled topic',
        );

        expect(snapshot.summary.totalConversations, 0);
        expect(snapshot.assistantRank, isEmpty);
      });
    });
  });
}
