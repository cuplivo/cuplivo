import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../models/stats_models.dart';

class StatsAggregationService {
  static StatsSnapshot buildSnapshot({
    required DateTime now,
    required StatsDateRange range,
    required List<Conversation> conversations,
    required Map<String, List<ChatMessage>> messagesByConversation,
    required int launchCount,
    required String unknownProviderLabel,
    required String unknownTopicLabel,
    Map<String, String> assistantNames = const {},
    Set<String>? existingAssistantIds,
    Map<String, String> providerNames = const {},
    StatsFilter filter = const StatsFilter(),
  }) {
    final rangeMessages = <ChatMessage>[];
    final heatmapCounts = <DateTime, int>{};
    final modelCounts = <String, int>{};
    final modelProviders = <String, String>{};
    final assistantCounts = <String, int>{};
    final topicCounts = <String, int>{};
    final topicLabels = <String, String>{};
    final matchingConversationIds = <String>{};

    var inputTokens = 0;
    var outputTokens = 0;
    var cachedTokens = 0;

    // Messages passing the filter, before the date-range cut. Reused by
    // _buildTrend so each message is matched exactly once per rebuild.
    final filteredByConversation = <String, List<ChatMessage>>{};

    for (final conversation in conversations) {
      final messages = messagesByConversation[conversation.id] ?? const [];
      final assistantId = conversation.assistantId?.trim().isNotEmpty == true
          ? conversation.assistantId!.trim()
          : StatsFilter.defaultAssistantId;

      for (final message in messages) {
        final messageDate = StatsDateRange.normalizeDate(message.timestamp);
        final modelId = message.modelId?.trim();
        final providerId = message.providerId?.trim();

        if (!filter.matches(
          modelId: modelId,
          assistantId: assistantId,
          topicId: conversation.id,
        )) {
          continue;
        }
        filteredByConversation
            .putIfAbsent(conversation.id, () => <ChatMessage>[])
            .add(message);

        heatmapCounts[messageDate] = (heatmapCounts[messageDate] ?? 0) + 1;

        if (!range.contains(message.timestamp)) continue;

        rangeMessages.add(message);
        matchingConversationIds.add(conversation.id);
        inputTokens += message.promptTokens ?? 0;
        outputTokens += message.completionTokens ?? 0;
        cachedTokens += message.cachedTokens ?? 0;

        if (modelId != null && modelId.isNotEmpty) {
          modelCounts[modelId] = (modelCounts[modelId] ?? 0) + 1;
          if (providerId != null && providerId.isNotEmpty) {
            modelProviders.putIfAbsent(modelId, () => providerId);
          }
        }

        topicCounts[conversation.id] = (topicCounts[conversation.id] ?? 0) + 1;
        final topicTitle = conversation.title.trim();
        topicLabels[conversation.id] = topicTitle.isEmpty
            ? unknownTopicLabel
            : topicTitle;
      }
    }

    // Assistant ranking counts conversations (not messages), keyed off
    // conversations that still hold at least one message inside the range AND
    // passing the filter. This deliberately changes the pre-filter semantics
    // (which counted every conversation created in range, even empty ones):
    // with an active filter the metric now reflects matching activity.
    for (final conversation in conversations) {
      if (!matchingConversationIds.contains(conversation.id)) continue;
      final assistantId = conversation.assistantId?.trim().isNotEmpty == true
          ? conversation.assistantId!.trim()
          : StatsFilter.defaultAssistantId;
      final assistantExists =
          existingAssistantIds == null ||
          assistantId == StatsFilter.defaultAssistantId ||
          existingAssistantIds.contains(assistantId);
      if (assistantExists) {
        assistantCounts[assistantId] =
            (assistantCounts[assistantId] ?? 0) + 1;
      }
    }

    final filteredConversationCount = matchingConversationIds.length;

    final trendRange = _trendRange(now, range);
    final trend = _buildTrend(
      trendRange: trendRange,
      filteredByConversation: filteredByConversation,
      providerNames: providerNames,
      unknownProviderLabel: unknownProviderLabel,
    );

    return StatsSnapshot(
      range: range,
      summary: StatsSummary(
        totalConversations: filteredConversationCount,
        totalMessages: rangeMessages.length,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cachedTokens: cachedTokens,
        launchCount: launchCount,
      ),
      heatmap: _buildHeatmap(now, heatmapCounts),
      trend: trend,
      modelRank: _rank(
        modelCounts,
        (id) => id,
        providerFor: (id) => modelProviders[id],
      ),
      assistantRank: _rank(assistantCounts, (id) => assistantNames[id] ?? id),
      topicRank: _rank(topicCounts, (id) => topicLabels[id] ?? id),
    );
  }

  static ({DateTime start, DateTime end}) _trendRange(
    DateTime now,
    StatsDateRange range,
  ) {
    final today = StatsDateRange.normalizeDate(now);
    if (range.isAllTime) {
      return (start: StatsDateRange.addCalendarDays(today, -29), end: today);
    }
    return (
      start: range.start ?? StatsDateRange.addCalendarDays(today, -29),
      end: range.end ?? today,
    );
  }

  static List<StatsHeatmapDay> _buildHeatmap(
    DateTime now,
    Map<DateTime, int> counts,
  ) {
    final today = StatsDateRange.normalizeDate(now);
    final start = StatsDateRange.addCalendarDays(today, -364);
    final days = <StatsHeatmapDay>[];
    for (
      var date = start;
      !date.isAfter(today);
      date = StatsDateRange.addCalendarDays(date, 1)
    ) {
      days.add(StatsHeatmapDay(date: date, count: counts[date] ?? 0));
    }
    return days;
  }

  static List<StatsTrendDay> _buildTrend({
    required ({DateTime start, DateTime end}) trendRange,
    required Map<String, List<ChatMessage>> filteredByConversation,
    required Map<String, String> providerNames,
    required String unknownProviderLabel,
  }) {
    final buckets = <DateTime, Map<String, StatsTokenBucket>>{};
    for (
      var date = trendRange.start;
      !date.isAfter(trendRange.end);
      date = StatsDateRange.addCalendarDays(date, 1)
    ) {
      buckets[date] = <String, StatsTokenBucket>{};
    }

    for (final messages in filteredByConversation.values) {
      for (final message in messages) {
        final date = StatsDateRange.normalizeDate(message.timestamp);
        if (date.isBefore(trendRange.start) || date.isAfter(trendRange.end)) {
          continue;
        }
        final inputTokens = message.promptTokens ?? 0;
        final outputTokens = message.completionTokens ?? 0;
        final legacyTotalTokens = message.totalTokens ?? 0;
        final cachedTokens = message.cachedTokens ?? 0;
        final uncategorizedTokens =
            inputTokens == 0 && outputTokens == 0 && legacyTotalTokens > 0
            ? legacyTotalTokens
            : 0;
        final providerId = message.providerId?.trim();
        if ((providerId == null || providerId.isEmpty) &&
            inputTokens == 0 &&
            outputTokens == 0 &&
            cachedTokens == 0 &&
            uncategorizedTokens == 0) {
          continue;
        }
        final providerLabel = providerId == null || providerId.isEmpty
            ? unknownProviderLabel
            : (providerNames[providerId] ?? providerId);
        final dayBuckets = buckets[date]!;
        final previous = dayBuckets[providerLabel] ?? const StatsTokenBucket();
        dayBuckets[providerLabel] = previous.add(
          inputTokens: inputTokens,
          outputTokens: outputTokens,
          cachedTokens: cachedTokens,
          uncategorizedTokens: uncategorizedTokens,
          activityCount: 1,
        );
      }
    }

    return [
      for (final entry in buckets.entries)
        StatsTrendDay(
          date: entry.key,
          providerTokens: Map.unmodifiable(entry.value),
        ),
    ];
  }

  static List<StatsRankItem> _rank(
    Map<String, int> counts,
    String Function(String id) labelFor, {
    String? Function(String id)? providerFor,
  }) {
    final entries = counts.entries.toList();
    entries.sort((a, b) {
      final byValue = b.value.compareTo(a.value);
      if (byValue != 0) return byValue;
      return 0;
    });
    return [
      for (final entry in entries)
        StatsRankItem(
          id: entry.key,
          label: labelFor(entry.key),
          value: entry.value,
          providerId: providerFor?.call(entry.key),
        ),
    ];
  }
}
