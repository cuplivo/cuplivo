enum StatsDateRangePreset {
  allTime,
  last30Days,
  previousMonth,
  previousQuarter,
  custom,
}

class StatsDateRange {
  const StatsDateRange._({
    required this.preset,
    required this.start,
    required this.end,
  });

  final StatsDateRangePreset preset;
  final DateTime? start;
  final DateTime? end;

  bool get isAllTime => preset == StatsDateRangePreset.allTime;

  factory StatsDateRange.allTime(DateTime now) {
    return const StatsDateRange._(
      preset: StatsDateRangePreset.allTime,
      start: null,
      end: null,
    );
  }

  factory StatsDateRange.last30Days(DateTime now) {
    final end = StatsDateRange.normalizeDate(now);
    return StatsDateRange._(
      preset: StatsDateRangePreset.last30Days,
      start: StatsDateRange.addCalendarDays(end, -29),
      end: end,
    );
  }

  factory StatsDateRange.previousMonth(DateTime now) {
    final monthStart = DateTime(now.year, now.month);
    final previousMonthEnd = StatsDateRange.addCalendarDays(monthStart, -1);
    return StatsDateRange._(
      preset: StatsDateRangePreset.previousMonth,
      start: DateTime(previousMonthEnd.year, previousMonthEnd.month),
      end: DateTime(
        previousMonthEnd.year,
        previousMonthEnd.month,
        previousMonthEnd.day,
      ),
    );
  }

  factory StatsDateRange.previousQuarter(DateTime now) {
    final currentQuarterStartMonth = ((now.month - 1) ~/ 3) * 3 + 1;
    final currentQuarterStart = DateTime(now.year, currentQuarterStartMonth);
    final previousQuarterEnd = StatsDateRange.addCalendarDays(
      currentQuarterStart,
      -1,
    );
    final previousQuarterStartMonth =
        ((previousQuarterEnd.month - 1) ~/ 3) * 3 + 1;
    return StatsDateRange._(
      preset: StatsDateRangePreset.previousQuarter,
      start: DateTime(previousQuarterEnd.year, previousQuarterStartMonth),
      end: DateTime(
        previousQuarterEnd.year,
        previousQuarterEnd.month,
        previousQuarterEnd.day,
      ),
    );
  }

  factory StatsDateRange.custom(DateTime start, DateTime end) {
    final normalizedStart = StatsDateRange.normalizeDate(start);
    final normalizedEnd = StatsDateRange.normalizeDate(end);
    if (normalizedEnd.isBefore(normalizedStart)) {
      throw ArgumentError.value(end, 'end', 'End date must not precede start');
    }
    return StatsDateRange._(
      preset: StatsDateRangePreset.custom,
      start: normalizedStart,
      end: normalizedEnd,
    );
  }

  static DateTime normalizeDate(DateTime value) {
    return DateTime(value.year, value.month, value.day);
  }

  static DateTime addCalendarDays(DateTime value, int days) {
    return DateTime(value.year, value.month, value.day + days);
  }

  bool contains(DateTime value) {
    if (isAllTime) return true;
    final date = normalizeDate(value);
    final rangeStart = start;
    final rangeEnd = end;
    if (rangeStart != null && date.isBefore(rangeStart)) return false;
    if (rangeEnd != null && date.isAfter(rangeEnd)) return false;
    return true;
  }
}

class StatsSummary {
  const StatsSummary({
    required this.totalConversations,
    required this.totalMessages,
    required this.inputTokens,
    required this.outputTokens,
    required this.cachedTokens,
    required this.launchCount,
  });

  final int totalConversations;
  final int totalMessages;
  final int inputTokens;
  final int outputTokens;
  final int cachedTokens;
  final int launchCount;
}

class StatsRankItem {
  const StatsRankItem({
    required this.id,
    required this.label,
    required this.value,
    this.providerId,
  });

  final String id;
  final String label;
  final int value;
  final String? providerId;
}

class StatsHeatmapDay {
  const StatsHeatmapDay({required this.date, required this.count});

  final DateTime date;
  final int count;
}

class StatsTokenBucket {
  const StatsTokenBucket({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedTokens = 0,
    this.uncategorizedTokens = 0,
    this.activityCount = 0,
  });

  final int inputTokens;
  final int outputTokens;
  final int cachedTokens;
  final int uncategorizedTokens;
  final int activityCount;

  int get totalTokens => inputTokens + outputTokens + uncategorizedTokens;
  int get chartWeight => totalTokens > 0 ? totalTokens : activityCount;

  StatsTokenBucket add({
    int inputTokens = 0,
    int outputTokens = 0,
    int cachedTokens = 0,
    int uncategorizedTokens = 0,
    int activityCount = 0,
  }) {
    return StatsTokenBucket(
      inputTokens: this.inputTokens + inputTokens,
      outputTokens: this.outputTokens + outputTokens,
      cachedTokens: this.cachedTokens + cachedTokens,
      uncategorizedTokens: this.uncategorizedTokens + uncategorizedTokens,
      activityCount: this.activityCount + activityCount,
    );
  }
}

class StatsTrendDay {
  const StatsTrendDay({required this.date, required this.providerTokens});

  final DateTime date;
  final Map<String, StatsTokenBucket> providerTokens;
}

class StatsSnapshot {
  const StatsSnapshot({
    required this.range,
    required this.summary,
    required this.heatmap,
    required this.trend,
    required this.modelRank,
    required this.assistantRank,
    required this.topicRank,
  });

  final StatsDateRange range;
  final StatsSummary summary;
  final List<StatsHeatmapDay> heatmap;
  final List<StatsTrendDay> trend;
  final List<StatsRankItem> modelRank;
  final List<StatsRankItem> assistantRank;
  final List<StatsRankItem> topicRank;
}

/// Optional dimension filters for the stats page.
///
/// Each non-empty set is an OR filter on its own dimension; dimensions
/// combine with AND. An empty set means "no restriction" on that dimension.
/// Clearing a dimension via [copyWith] means passing an *empty* set —
/// `null` keeps the current value.
class StatsFilter {
  /// Sentinel assistant id for conversations without an assistant. Shared by
  /// the filter option in the page and the normalisation in the aggregation
  /// service, so the string is defined exactly once.
  static const String defaultAssistantId = '_default';

  const StatsFilter({
    this.modelIds = const {},
    this.assistantIds = const {},
    this.topicIds = const {},
  });

  final Set<String> modelIds;
  final Set<String> assistantIds;
  final Set<String> topicIds;

  bool get isActive =>
      modelIds.isNotEmpty ||
      assistantIds.isNotEmpty ||
      topicIds.isNotEmpty;

  bool matches({
    required String? modelId,
    required String? assistantId,
    required String? topicId,
  }) {
    if (modelIds.isNotEmpty &&
        (modelId == null || !modelIds.contains(modelId))) {
      return false;
    }
    if (assistantIds.isNotEmpty &&
        (assistantId == null || !assistantIds.contains(assistantId))) {
      return false;
    }
    if (topicIds.isNotEmpty &&
        (topicId == null || !topicIds.contains(topicId))) {
      return false;
    }
    return true;
  }

  StatsFilter copyWith({
    Set<String>? modelIds,
    Set<String>? assistantIds,
    Set<String>? topicIds,
  }) {
    return StatsFilter(
      modelIds: modelIds ?? this.modelIds,
      assistantIds: assistantIds ?? this.assistantIds,
      topicIds: topicIds ?? this.topicIds,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is StatsFilter &&
        _sameIds(other.modelIds, modelIds) &&
        _sameIds(other.assistantIds, assistantIds) &&
        _sameIds(other.topicIds, topicIds);
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(modelIds),
    Object.hashAllUnordered(assistantIds),
    Object.hashAllUnordered(topicIds),
  );

  static bool _sameIds(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  @override
  String toString() =>
      'StatsFilter(models: ${modelIds.length}, assistants: '
      '${assistantIds.length}, topics: ${topicIds.length})';
}
