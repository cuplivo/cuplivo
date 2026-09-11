import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_checkbox.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../home/widgets/assistant_avatar.dart';
import '../../home/widgets/model_icon.dart';
import '../models/stats_models.dart';
import '../services/stats_aggregation_service.dart';
import '../widgets/stats_heatmap.dart';
import '../widgets/stats_metric_grid.dart';
import '../widgets/stats_rank_section.dart';
import '../widgets/stats_section_card.dart';
import '../widgets/stats_usage_chart.dart';
import '../../../theme/app_font_weights.dart';

class StatsPage extends StatefulWidget {
  const StatsPage({super.key, this.snapshotOverride, this.showAppBar = true});

  final StatsSnapshot? snapshotOverride;
  final bool showAppBar;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  late StatsDateRange _range;
  StatsFilter _filter = const StatsFilter();

  @override
  void initState() {
    super.initState();
    _range =
        widget.snapshotOverride?.range ??
        StatsDateRange.allTime(DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final snapshot = widget.snapshotOverride ?? _buildSnapshot(context);
    final assistantById = widget.snapshotOverride == null
        ? {
            for (final assistant
                in context.watch<AssistantProvider>().assistants)
              assistant.id: assistant,
          }
        : <String, Assistant>{};
    final body = ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _RangeSelector(
          selected: _range.preset,
          onChanged: _setPreset,
          onCustom: _pickCustomRange,
        ),
        if (widget.snapshotOverride == null) ...[
          const SizedBox(height: 8),
          _FilterBar(
            filter: _filter,
            onModelProviderTap: _pickModelProviderFilter,
            onAssistantTap: _pickAssistantFilter,
            onTopicTap: _pickTopicFilter,
            onClearAll: _filter.isActive
                ? () => setState(() => _filter = const StatsFilter())
                : null,
          ),
        ],
        const SizedBox(height: 12),
        StatsSectionCard(
          title: l10n.statsPageHeatmapTitle,
          child: StatsHeatmap(days: snapshot.heatmap),
        ),
        const SizedBox(height: 12),
        StatsSectionCard(
          title: l10n.statsPageSummaryTitle,
          child: StatsMetricGrid(summary: snapshot.summary),
        ),
        const SizedBox(height: 12),
        StatsSectionCard(
          title: l10n.statsPageUsageTrendTitle,
          child: StatsUsageChart(days: snapshot.trend),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 820;
            final sections = [
              StatsRankSection(
                title: l10n.statsPageModelUsageTitle,
                leftHeader: l10n.statsPageModelColumn,
                rightHeader: l10n.statsPageMessagesColumn,
                items: snapshot.modelRank,
                leadingBuilder: (context, item) => CurrentModelIcon(
                  key: ValueKey('stats-model-icon-${item.id}'),
                  providerKey: item.providerId,
                  modelId: item.id,
                  size: 32,
                  withBackground: false,
                ),
              ),
              StatsRankSection(
                title: l10n.statsPageAssistantUsageTitle,
                leftHeader: l10n.statsPageAssistantColumn,
                rightHeader: l10n.statsPageTopicsColumn,
                items: snapshot.assistantRank,
                leadingBuilder: (context, item) => AssistantAvatar(
                  key: ValueKey('stats-assistant-avatar-${item.id}'),
                  assistant: assistantById[item.id],
                  fallbackName: item.label,
                  size: 20,
                ),
              ),
              StatsRankSection(
                title: l10n.statsPageTopicVolumeTitle,
                leftHeader: l10n.statsPageTopicColumn,
                rightHeader: l10n.statsPageMessagesColumn,
                items: snapshot.topicRank,
                icon: Lucide.MessageSquare,
              ),
            ];
            if (!wide) {
              return Column(
                children: [
                  for (var i = 0; i < sections.length; i++) ...[
                    sections[i],
                    if (i != sections.length - 1) const SizedBox(height: 12),
                  ],
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < sections.length; i++) ...[
                  Expanded(child: sections[i]),
                  if (i != sections.length - 1) const SizedBox(width: 12),
                ],
              ],
            );
          },
        ),
      ],
    );

    if (!widget.showAppBar) return body;
    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            minSize: 44,
            size: 22,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.statsPageTitle),
      ),
      body: body,
    );
  }

  StatsSnapshot _buildSnapshot(BuildContext context) {
    final now = DateTime.now();
    final l10n = AppLocalizations.of(context)!;
    final chatService = context.watch<ChatService>();
    final settings = context.watch<SettingsProvider>();
    final assistantProvider = context.watch<AssistantProvider>();
    final conversations = chatService.getAllCompleteConversations();
    final messagesByConversation = {
      for (final conversation in conversations)
        conversation.id: chatService.getMessages(conversation.id),
    };
    final assistantNames = {
      for (final assistant in assistantProvider.assistants)
        assistant.id: assistant.name,
      StatsFilter.defaultAssistantId: l10n.statsPageUnknownAssistant,
    };
    final existingAssistantIds = {
      for (final assistant in assistantProvider.assistants) assistant.id,
      StatsFilter.defaultAssistantId,
    };
    final providerNames = {
      for (final entry in settings.providerConfigs.entries)
        entry.key: entry.value.name,
    };
    return StatsAggregationService.buildSnapshot(
      now: now,
      range: _range,
      filter: _filter,
      conversations: conversations,
      messagesByConversation: messagesByConversation,
      launchCount: settings.appLaunchCount,
      assistantNames: assistantNames,
      existingAssistantIds: existingAssistantIds,
      providerNames: providerNames,
      unknownProviderLabel: l10n.statsPageUnknownProvider,
      unknownTopicLabel: l10n.statsPageUnknownTopic,
    );
  }

  void _setPreset(StatsDateRangePreset preset) {
    final now = DateTime.now();
    setState(() {
      _range = switch (preset) {
        StatsDateRangePreset.allTime => StatsDateRange.allTime(now),
        StatsDateRangePreset.last30Days => StatsDateRange.last30Days(now),
        StatsDateRangePreset.previousMonth => StatsDateRange.previousMonth(now),
        StatsDateRangePreset.previousQuarter => StatsDateRange.previousQuarter(
          now,
        ),
        StatsDateRangePreset.custom => _range,
      };
    });
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final end = StatsDateRange.normalizeDate(now);
    final start = StatsDateRange.addCalendarDays(end, -29);
    final initialRange = DateTimeRange(
      start: _range.start ?? start,
      end: _range.end ?? end,
    );
    final selected = await _showCustomRangePicker(
      context,
      initialRange: initialRange,
      firstDate: DateTime(2000),
      lastDate: end,
    );
    if (selected == null) return;
    setState(() {
      _range = StatsDateRange.custom(selected.start, selected.end);
    });
  }

  Future<void> _pickModelProviderFilter() async {
    final chatService = context.read<ChatService>();
    final settings = context.read<SettingsProvider>();
    final l10n = AppLocalizations.of(context)!;
    final modelProviders = <String, String>{};
    for (final conversation in chatService.getAllCompleteConversations()) {
      for (final message in chatService.getMessages(conversation.id)) {
        final modelId = message.modelId?.trim();
        if (modelId == null || modelId.isEmpty) continue;
        // Keep provider-less models: they land in the unknown bucket
        // instead of becoming unfilterable. First writer wins — the
        // repository enumerates updated_at DESC, so the newest observed
        // model->provider mapping sticks.
        modelProviders.putIfAbsent(
          modelId,
          () => message.providerId?.trim() ?? '',
        );
      }
    }
    final providerNames = {
      for (final entry in settings.providerConfigs.entries)
        entry.key: entry.value.name,
    };
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _ModelProviderFilterSheet(
        modelProviders: modelProviders,
        providerNames: providerNames,
        unknownProviderLabel: l10n.statsPageUnknownProvider,
        initialModelIds: _filter.modelIds,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _filter = _filter.copyWith(modelIds: result);
    });
  }

  Future<void> _pickAssistantFilter() async {
    final assistantProvider = context.read<AssistantProvider>();
    final l10n = AppLocalizations.of(context)!;
    final options = <({String id, String label})>[
      for (final a in assistantProvider.assistants)
        (
          id: a.id,
          label: a.name.trim().isEmpty
              ? l10n.bindingsUnnamedAssistant
              : a.name.trim(),
        ),
      (
        id: StatsFilter.defaultAssistantId,
        label: l10n.statsPageUnknownAssistant,
      ),
    ];
    final selected = await _showSimpleFilterSheet(
      title: l10n.statsPageFilterAssistantSelectTitle,
      options: options,
      initialSelected: _filter.assistantIds,
    );
    if (selected == null || !mounted) return;
    setState(() => _filter = _filter.copyWith(assistantIds: selected));
  }

  Future<void> _pickTopicFilter() async {
    final chatService = context.read<ChatService>();
    final l10n = AppLocalizations.of(context)!;
    final options = <({String id, String label})>[
      for (final c in chatService.getAllCompleteConversations())
        if (c.messageIds.isNotEmpty)
          (
            id: c.id,
            label: c.title.trim().isEmpty
                ? l10n.statsPageUnknownTopic
                : c.title.trim(),
          ),
    ];
    final selected = await _showSimpleFilterSheet(
      title: l10n.statsPageFilterTopicSelectTitle,
      options: options,
      initialSelected: _filter.topicIds,
    );
    if (selected == null || !mounted) return;
    setState(() => _filter = _filter.copyWith(topicIds: selected));
  }

  Future<Set<String>?> _showSimpleFilterSheet({
    required String title,
    required List<({String id, String label})> options,
    required Set<String> initialSelected,
  }) {
    return showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _SimpleFilterSheet(
        title: title,
        options: options,
        initialSelected: initialSelected,
      ),
    );
  }
}

class _RangeSelector extends StatelessWidget {
  const _RangeSelector({
    required this.selected,
    required this.onChanged,
    required this.onCustom,
  });

  final StatsDateRangePreset selected;
  final ValueChanged<StatsDateRangePreset> onChanged;
  final VoidCallback onCustom;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final options = [
      (StatsDateRangePreset.allTime, l10n.statsPageRangeAllTime),
      (StatsDateRangePreset.last30Days, l10n.statsPageRangeLast30Days),
      (StatsDateRangePreset.previousMonth, l10n.statsPageRangePreviousMonth),
      (
        StatsDateRangePreset.previousQuarter,
        l10n.statsPageRangePreviousQuarter,
      ),
      (StatsDateRangePreset.custom, l10n.statsPageRangeCustom),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < options.length; i++) ...[
            _RangeButton(
              label: options[i].$2,
              selected: selected == options[i].$1,
              onTap: () {
                if (options[i].$1 == StatsDateRangePreset.custom) {
                  onCustom();
                } else {
                  onChanged(options[i].$1);
                }
              },
            ),
            if (i != options.length - 1) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

Future<DateTimeRange?> _showCustomRangePicker(
  BuildContext context, {
  required DateTimeRange initialRange,
  required DateTime firstDate,
  required DateTime lastDate,
}) {
  final isDesktopWidth = MediaQuery.sizeOf(context).width >= 720;
  if (isDesktopWidth) {
    return showDialog<DateTimeRange>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        backgroundColor: Colors.transparent,
        child: _CustomRangeSheet(
          initialRange: initialRange,
          firstDate: firstDate,
          lastDate: lastDate,
          desktop: true,
        ),
      ),
    );
  }
  return showModalBottomSheet<DateTimeRange>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _CustomRangeSheet(
      initialRange: initialRange,
      firstDate: firstDate,
      lastDate: lastDate,
    ),
  );
}

class _RangeButton extends StatelessWidget {
  const _RangeButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selectedBackground = isDark
        ? Colors.white.withValues(alpha: 0.16)
        : const Color(0xFFD9DDE2); // color-gate: ignore
    final idleBackground = isDark
        ? cs.onSurface.withValues(alpha: 0.06)
        : const Color(0xFFEEF0F3);
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          height: 32,
          constraints: const BoxConstraints(minWidth: 64),
          padding: const EdgeInsets.symmetric(horizontal: 13),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? selectedBackground : idleBackground,
            borderRadius: BorderRadius.circular(15),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected
                  ? cs.onSurface.withValues(alpha: 0.9)
                  : cs.onSurface.withValues(alpha: isDark ? 0.7 : 0.62),
              fontSize: 12,
              fontWeight: selected
                  ? AppFontWeights.emphasis
                  : AppFontWeights.semibold,
            ),
          ),
        ),
      ),
    );
  }
}

class _CustomRangeSheet extends StatefulWidget {
  const _CustomRangeSheet({
    required this.initialRange,
    required this.firstDate,
    required this.lastDate,
    this.desktop = false,
  });

  final DateTimeRange initialRange;
  final DateTime firstDate;
  final DateTime lastDate;
  final bool desktop;

  @override
  State<_CustomRangeSheet> createState() => _CustomRangeSheetState();
}

class _CustomRangeSheetState extends State<_CustomRangeSheet> {
  late DateTime _start;
  late DateTime _end;

  @override
  void initState() {
    super.initState();
    _start = StatsDateRange.normalizeDate(widget.initialRange.start);
    _end = StatsDateRange.normalizeDate(widget.initialRange.end);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final content = Container(
      width: widget.desktop ? 420 : double.infinity,
      margin: widget.desktop
          ? EdgeInsets.zero
          : EdgeInsets.only(left: 12, right: 12, bottom: 12 + bottomInset),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F2023) : const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(widget.desktop ? 18 : 22),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.statsPageCustomRangeTitle,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.92),
                    fontSize: 15,
                    fontWeight: AppFontWeights.emphasis,
                  ),
                ),
              ),
              IosIconButton(
                icon: Lucide.X,
                size: 18,
                padding: const EdgeInsets.all(7),
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _DateField(
                  label: l10n.statsPageCustomRangeStart,
                  date: _start,
                  onTap: () => _pickDate(start: true),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _DateField(
                  label: l10n.statsPageCustomRangeEnd,
                  date: _end,
                  onTap: () => _pickDate(start: false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: IosCardPress(
                  onTap: () => Navigator.of(context).pop(),
                  borderRadius: BorderRadius.circular(13),
                  baseColor: isDark
                      ? cs.onSurface.withValues(alpha: 0.08)
                      : const Color(0xFFE7E9EC),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  child: Center(
                    child: Text(
                      l10n.statsPageCustomRangeCancel,
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.74),
                        fontSize: 13,
                        fontWeight: AppFontWeights.emphasis,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: IosCardPress(
                  onTap: () => Navigator.of(
                    context,
                  ).pop(DateTimeRange(start: _start, end: _end)),
                  borderRadius: BorderRadius.circular(13),
                  baseColor: isDark
                      ? Colors.white.withValues(alpha: 0.16)
                      : const Color(0xFFDADDE2), // color-gate: ignore
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  child: Center(
                    child: Text(
                      l10n.statsPageCustomRangeApply,
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.9),
                        fontSize: 13,
                        fontWeight: AppFontWeights.heavy,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (widget.desktop) return content;
    return SafeArea(top: false, child: content);
  }

  Future<void> _pickDate({required bool start}) async {
    final initial = start ? _start : _end;
    final selected = await _showStatsDatePicker(
      context,
      firstDate: widget.firstDate,
      lastDate: widget.lastDate,
      initialDate: initial,
    );
    if (selected == null) return;
    final date = StatsDateRange.normalizeDate(selected);
    setState(() {
      if (start) {
        _start = date;
        if (_end.isBefore(_start)) _end = _start;
      } else {
        _end = date;
        if (_start.isAfter(_end)) _start = _end;
      }
    });
  }
}

Future<DateTime?> _showStatsDatePicker(
  BuildContext context, {
  required DateTime firstDate,
  required DateTime lastDate,
  required DateTime initialDate,
}) {
  final isDesktopWidth = MediaQuery.sizeOf(context).width >= 720;
  final normalizedInitial = StatsDateRange.normalizeDate(initialDate);
  if (isDesktopWidth) {
    return showDialog<DateTime>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        backgroundColor: Colors.transparent,
        child: _StatsDatePickerPanel(
          firstDate: firstDate,
          lastDate: lastDate,
          initialDate: normalizedInitial,
          desktop: true,
        ),
      ),
    );
  }

  return showModalBottomSheet<DateTime>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _StatsDatePickerPanel(
      firstDate: firstDate,
      lastDate: lastDate,
      initialDate: normalizedInitial,
    ),
  );
}

class _StatsDatePickerPanel extends StatefulWidget {
  const _StatsDatePickerPanel({
    required this.firstDate,
    required this.lastDate,
    required this.initialDate,
    this.desktop = false,
  });

  final DateTime firstDate;
  final DateTime lastDate;
  final DateTime initialDate;
  final bool desktop;

  @override
  State<_StatsDatePickerPanel> createState() => _StatsDatePickerPanelState();
}

class _StatsDatePickerPanelState extends State<_StatsDatePickerPanel> {
  late DateTime _visibleMonth;
  late DateTime _selectedDate;
  var _mode = _CalendarPickerMode.day;

  @override
  void initState() {
    super.initState();
    _selectedDate = StatsDateRange.normalizeDate(widget.initialDate);
    _visibleMonth = DateTime(_selectedDate.year, _selectedDate.month);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final content = Container(
      width: widget.desktop ? 360 : double.infinity,
      margin: widget.desktop
          ? EdgeInsets.zero
          : EdgeInsets.only(left: 12, right: 12, bottom: 12 + bottomInset),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F2023) : const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(widget.desktop ? 18 : 22),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        key: const ValueKey('stats-custom-date-calendar'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IosIconButton(
                key: const ValueKey('stats-date-picker-prev-year'),
                icon: Lucide.ChevronLeft,
                size: 18,
                padding: const EdgeInsets.all(7),
                onTap: _mode == _CalendarPickerMode.day
                    ? (_canShowPreviousMonth() ? () => _shiftMonth(-1) : null)
                    : (_canShowPreviousYear() ? () => _shiftYear(-1) : null),
              ),
              Expanded(
                child: Center(
                  child: IosCardPress(
                    key: const ValueKey('stats-date-picker-title'),
                    onTap: () => setState(() {
                      _mode = _mode == _CalendarPickerMode.day
                          ? _CalendarPickerMode.month
                          : _CalendarPickerMode.day;
                    }),
                    borderRadius: BorderRadius.circular(13),
                    baseColor: isDark
                        ? cs.onSurface.withValues(alpha: 0.08)
                        : const Color(0xFFECEEF1),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 7,
                    ),
                    child: Text(
                      _mode == _CalendarPickerMode.day
                          ? DateFormat('yyyy-MM').format(_visibleMonth)
                          : DateFormat('yyyy').format(_visibleMonth),
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.9),
                        fontSize: 15,
                        fontWeight: AppFontWeights.heavy,
                      ),
                    ),
                  ),
                ),
              ),
              IosIconButton(
                key: const ValueKey('stats-date-picker-next-year'),
                icon: Lucide.ChevronRight,
                size: 18,
                padding: const EdgeInsets.all(7),
                onTap: _mode == _CalendarPickerMode.day
                    ? (_canShowNextMonth() ? () => _shiftMonth(1) : null)
                    : (_canShowNextYear() ? () => _shiftYear(1) : null),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_mode == _CalendarPickerMode.day) ...[
            Row(
              children: [
                for (final label in _weekdayLabels(context))
                  Expanded(
                    child: Center(
                      child: Text(
                        label,
                        style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.42),
                          fontSize: 11,
                          fontWeight: AppFontWeights.emphasis,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 7),
            _MonthGrid(
              visibleMonth: _visibleMonth,
              selectedDate: _selectedDate,
              firstDate: StatsDateRange.normalizeDate(widget.firstDate),
              lastDate: StatsDateRange.normalizeDate(widget.lastDate),
              onSelected: (date) {
                _selectedDate = date;
                Navigator.of(context).pop(date);
              },
            ),
          ] else
            _YearMonthGrid(
              visibleMonth: _visibleMonth,
              selectedDate: _selectedDate,
              firstDate: StatsDateRange.normalizeDate(widget.firstDate),
              lastDate: StatsDateRange.normalizeDate(widget.lastDate),
              onSelected: (month) {
                setState(() {
                  _visibleMonth = DateTime(_visibleMonth.year, month);
                  _mode = _CalendarPickerMode.day;
                });
              },
            ),
        ],
      ),
    );

    if (widget.desktop) return content;
    return SafeArea(top: false, child: content);
  }

  bool _canShowPreviousYear() {
    return _visibleMonth.year > widget.firstDate.year;
  }

  bool _canShowNextYear() {
    return _visibleMonth.year < widget.lastDate.year;
  }

  bool _canShowPreviousMonth() {
    final firstMonth = DateTime(widget.firstDate.year, widget.firstDate.month);
    return _visibleMonth.isAfter(firstMonth);
  }

  bool _canShowNextMonth() {
    final lastMonth = DateTime(widget.lastDate.year, widget.lastDate.month);
    return _visibleMonth.isBefore(lastMonth);
  }

  void _shiftMonth(int delta) {
    setState(() {
      _visibleMonth = _clampVisibleMonth(
        DateTime(_visibleMonth.year, _visibleMonth.month + delta),
      );
    });
  }

  void _shiftYear(int delta) {
    setState(() {
      _visibleMonth = _clampVisibleMonth(
        DateTime(_visibleMonth.year + delta, _visibleMonth.month),
      );
    });
  }

  DateTime _clampVisibleMonth(DateTime month) {
    final firstMonth = DateTime(widget.firstDate.year, widget.firstDate.month);
    final lastMonth = DateTime(widget.lastDate.year, widget.lastDate.month);
    if (month.isBefore(firstMonth)) return firstMonth;
    if (month.isAfter(lastMonth)) return lastMonth;
    return month;
  }

  List<String> _weekdayLabels(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    final weekStart = DateTime(2026, 5, 4);
    final formatter = DateFormat.E(locale);
    return [
      for (var i = 0; i < 7; i++)
        formatter.format(StatsDateRange.addCalendarDays(weekStart, i)),
    ];
  }
}

enum _CalendarPickerMode { day, month }

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.visibleMonth,
    required this.selectedDate,
    required this.firstDate,
    required this.lastDate,
    required this.onSelected,
  });

  final DateTime visibleMonth;
  final DateTime selectedDate;
  final DateTime firstDate;
  final DateTime lastDate;
  final ValueChanged<DateTime> onSelected;

  @override
  Widget build(BuildContext context) {
    final monthStart = DateTime(visibleMonth.year, visibleMonth.month);
    final gridStart = StatsDateRange.addCalendarDays(
      monthStart,
      DateTime.monday - monthStart.weekday,
    );
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        mainAxisSpacing: 7,
        crossAxisSpacing: 7,
      ),
      itemCount: 42,
      itemBuilder: (context, index) {
        final date = StatsDateRange.addCalendarDays(gridStart, index);
        return _DateCell(
          date: date,
          inVisibleMonth: date.month == visibleMonth.month,
          selected: StatsDateRange.normalizeDate(date) == selectedDate,
          enabled: !date.isBefore(firstDate) && !date.isAfter(lastDate),
          onTap: () => onSelected(StatsDateRange.normalizeDate(date)),
        );
      },
    );
  }
}

class _YearMonthGrid extends StatelessWidget {
  const _YearMonthGrid({
    required this.visibleMonth,
    required this.selectedDate,
    required this.firstDate,
    required this.lastDate,
    required this.onSelected,
  });

  final DateTime visibleMonth;
  final DateTime selectedDate;
  final DateTime firstDate;
  final DateTime lastDate;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    final formatter = DateFormat.MMM(locale);
    return GridView.builder(
      key: const ValueKey('stats-custom-month-picker'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1.85,
      ),
      itemCount: 12,
      itemBuilder: (context, index) {
        final month = index + 1;
        final monthDate = DateTime(visibleMonth.year, month);
        final enabled =
            !_monthIsBefore(monthDate, firstDate) &&
            !_monthIsAfter(monthDate, lastDate);
        return _MonthCell(
          key: ValueKey('stats-month-cell-$month'),
          label: formatter.format(monthDate),
          selected:
              selectedDate.year == visibleMonth.year &&
              selectedDate.month == month,
          enabled: enabled,
          onTap: () => onSelected(month),
        );
      },
    );
  }

  bool _monthIsBefore(DateTime month, DateTime boundary) {
    return month.year < boundary.year ||
        (month.year == boundary.year && month.month < boundary.month);
  }

  bool _monthIsAfter(DateTime month, DateTime boundary) {
    return month.year > boundary.year ||
        (month.year == boundary.year && month.month > boundary.month);
  }
}

class _MonthCell extends StatelessWidget {
  const _MonthCell({
    super.key,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = selected
        ? (isDark
              ? Colors.white.withValues(alpha: 0.18)
              : const Color(0xFFDADDE2)) // color-gate: ignore
        : (isDark
              ? cs.onSurface.withValues(alpha: 0.06)
              : const Color(0xFFECEEF1));
    return IosCardPress(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(13),
      baseColor: background,
      pressedBlendStrength: selected ? 0 : null,
      padding: EdgeInsets.zero,
      child: Center(
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: cs.onSurface.withValues(alpha: enabled ? 0.82 : 0.22),
            fontSize: 12,
            fontWeight: selected
                ? AppFontWeights.heavy
                : AppFontWeights.emphasis,
          ),
        ),
      ),
    );
  }
}

class _DateCell extends StatelessWidget {
  const _DateCell({
    required this.date,
    required this.inVisibleMonth,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final DateTime date;
  final bool inVisibleMonth;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = selected
        ? (isDark
              ? Colors.white.withValues(alpha: 0.18)
              : const Color(0xFFDADDE2)) // color-gate: ignore
        : Colors.transparent;
    final alpha = !enabled
        ? 0.18
        : inVisibleMonth
        ? 0.82
        : 0.34;
    return IosCardPress(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(12),
      baseColor: background,
      pressedBlendStrength: selected ? 0 : null,
      padding: EdgeInsets.zero,
      child: Center(
        child: Text(
          date.day.toString(),
          style: TextStyle(
            color: cs.onSurface.withValues(alpha: alpha),
            fontSize: 12,
            fontWeight: selected
                ? AppFontWeights.heavy
                : AppFontWeights.semibold,
          ),
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.date,
    required this.onTap,
  });

  final String label;
  final DateTime date;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IosCardPress(
      onTap: onTap,
      borderRadius: BorderRadius.circular(13),
      baseColor: isDark
          ? cs.onSurface.withValues(alpha: 0.07)
          : const Color(0xFFECEEF1),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.52),
              fontSize: 11,
              fontWeight: AppFontWeights.semibold,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            DateFormat('yyyy-MM-dd').format(date),
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.9),
              fontSize: 13,
              fontWeight: AppFontWeights.emphasis,
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.filter,
    required this.onModelProviderTap,
    required this.onAssistantTap,
    required this.onTopicTap,
    this.onClearAll,
  });

  final StatsFilter filter;
  final VoidCallback onModelProviderTap;
  final VoidCallback onAssistantTap;
  final VoidCallback onTopicTap;
  final VoidCallback? onClearAll;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final modelCount = filter.modelIds.length;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(right: 16),
      child: Row(
        children: [
          _FilterChipButton(
            label: l10n.statsPageFilterModels,
            count: modelCount,
            selected: modelCount > 0,
            onTap: onModelProviderTap,
          ),
          const SizedBox(width: 8),
          _FilterChipButton(
            label: l10n.statsPageFilterAssistants,
            count: filter.assistantIds.length,
            selected: filter.assistantIds.isNotEmpty,
            onTap: onAssistantTap,
          ),
          const SizedBox(width: 8),
          _FilterChipButton(
            label: l10n.statsPageFilterTopics,
            count: filter.topicIds.length,
            selected: filter.topicIds.isNotEmpty,
            onTap: onTopicTap,
          ),
          if (onClearAll != null) ...[
            const SizedBox(width: 8),
            _FilterChipButton(
              label: l10n.statsPageFilterClearAll,
              count: null,
              selected: false,
              accent: true,
              onTap: onClearAll,
            ),
          ],
        ],
      ),
    );
  }
}

class _FilterChipButton extends StatelessWidget {
  const _FilterChipButton({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    this.accent = false,
  });

  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selectedBackground = isDark
        ? Colors.white.withValues(alpha: 0.16)
        : const Color(0xFFD9DDE2); // color-gate: ignore
    final accentBackground = cs.primary.withValues(alpha: isDark ? 0.35 : 0.18);
    final idleBackground = isDark
        ? cs.onSurface.withValues(alpha: 0.06)
        : const Color(0xFFEEF0F3);
    final text = count != null && count! > 0 ? '$label ($count)' : label;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 64, minHeight: 32),
      child: Semantics(
        button: true,
        selected: selected,
        child: IosCardPress(
          onTap: onTap,
          baseColor: accent
              ? accentBackground
              : selected
              ? selectedBackground
              : idleBackground,
          borderRadius: BorderRadius.circular(15),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          child: Center(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: accent
                    ? cs.primary
                    : selected
                    ? cs.onSurface.withValues(alpha: 0.9)
                    : cs.onSurface.withValues(alpha: isDark ? 0.7 : 0.62),
                fontSize: 12,
                fontWeight: selected || accent
                    ? AppFontWeights.emphasis
                    : AppFontWeights.semibold,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.label,
    required this.checked,
    required this.onTap,
    this.subtitle,
    this.indent = false,
  });

  final String label;
  final bool checked;
  final VoidCallback onTap;
  final String? subtitle;
  final bool indent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IosCardPress(
      baseColor: Colors.transparent,
      borderRadius: BorderRadius.zero,
      pressedBlendStrength: 0,
      pressedScale: 1.0,
      haptics: false,
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          indent ? 28 : 12,
          9,
          12,
          9,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: subtitle == null ? 14.5 : 14,
                      fontWeight: AppFontWeights.medium,
                      color: cs.onSurface.withValues(alpha: 0.88),
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            IosCheckbox(
              value: checked,
              onChanged: (_) => onTap(),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom-sheet multi-select for models, grouped by provider. Checking a
/// provider header selects all its models; individual model rows toggle
/// single models. Returns the selected model id set (empty = no filter).
class _ModelProviderFilterSheet extends StatefulWidget {
  const _ModelProviderFilterSheet({
    required this.modelProviders,
    required this.providerNames,
    required this.unknownProviderLabel,
    required this.initialModelIds,
  });

  final Map<String, String> modelProviders;
  final Map<String, String> providerNames;
  final String unknownProviderLabel;
  final Set<String> initialModelIds;

  @override
  State<_ModelProviderFilterSheet> createState() =>
      _ModelProviderFilterSheetState();
}

class _ModelProviderFilterSheetState extends State<_ModelProviderFilterSheet> {
  late final Set<String> _modelIds = Set.of(widget.initialModelIds);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    // Group models by provider; models without a provider go to the unknown
    // bucket, keeping insertion order for stability.
    final groups = <String, List<String>>{};
    final groupOrder = <String>[];
    widget.modelProviders.forEach((modelId, providerId) {
      // Group by the raw provider id: display names are user-editable and
      // not deduplicated, so labelling here would merge distinct providers
      // (and a provider literally named like the unknown label would fold
      // into the synthetic bucket). Resolve the label only when rendering.
      final key = providerId.trim();
      if (!groups.containsKey(key)) {
        groups[key] = <String>[];
        groupOrder.add(key);
      }
      groups[key]!.add(modelId);
    });

    return Container(
      width: double.infinity,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.75,
      ),
      margin: EdgeInsets.only(left: 12, right: 12, bottom: 12 + bottomInset),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F2023) : const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(22),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.statsPageFilterModelSelectTitle,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.92),
                    fontSize: 15,
                    fontWeight: AppFontWeights.emphasis,
                  ),
                ),
              ),
              IosIconButton(
                icon: Lucide.X,
                size: 18,
                padding: const EdgeInsets.all(7),
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (groupOrder.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        l10n.statsPageFilterNoOptions,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                  for (final provider in groupOrder) ...[
                    _CheckRow(
                      label: provider.isEmpty
                          ? widget.unknownProviderLabel
                          : (widget.providerNames[provider] ?? provider),
                      checked: groups[provider]!
                          .every((m) => _modelIds.contains(m)),
                      onTap: () {
                        setState(() {
                          final allSelected = groups[provider]!
                              .every((m) => _modelIds.contains(m));
                          if (allSelected) {
                            _modelIds.removeAll(groups[provider]!);
                          } else {
                            _modelIds.addAll(groups[provider]!);
                          }
                        });
                      },
                    ),
                    for (final modelId in groups[provider]!)
                      _CheckRow(
                        label: modelId,
                        checked: _modelIds.contains(modelId),
                        onTap: () {
                          setState(() {
                            if (_modelIds.contains(modelId)) {
                              _modelIds.remove(modelId);
                            } else {
                              _modelIds.add(modelId);
                            }
                          });
                        },
                        indent: true,
                      ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: IosCardPress(
                  onTap: () {
                    setState(() => _modelIds.clear());
                  },
                  borderRadius: BorderRadius.circular(13),
                  baseColor: isDark
                      ? cs.onSurface.withValues(alpha: 0.08)
                      : const Color(0xFFE7E9EC),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  child: Center(
                    child: Text(
                      l10n.statsPageFilterClear,
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.74),
                        fontSize: 13,
                        fontWeight: AppFontWeights.emphasis,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: IosCardPress(
                  onTap: () =>
                      Navigator.of(context).pop(Set.of(_modelIds)),
                  borderRadius: BorderRadius.circular(13),
                  baseColor: isDark
                      ? Colors.white.withValues(alpha: 0.16)
                      : const Color(0xFFDADDE2), // color-gate: ignore
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  child: Center(
                    child: Text(
                      l10n.statsPageFilterDone,
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.9),
                        fontSize: 13,
                        fontWeight: AppFontWeights.heavy,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Bottom-sheet multi-select for assistants / topics. Returns the selected
/// id set (empty = no filter), or null when dismissed.
class _SimpleFilterSheet extends StatefulWidget {
  const _SimpleFilterSheet({
    required this.title,
    required this.options,
    required this.initialSelected,
  });

  final String title;
  final List<({String id, String label})> options;
  final Set<String> initialSelected;

  @override
  State<_SimpleFilterSheet> createState() => _SimpleFilterSheetState();
}

class _SimpleFilterSheetState extends State<_SimpleFilterSheet> {
  late final Set<String> _selected = Set.of(widget.initialSelected);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Container(
      width: double.infinity,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.75,
      ),
      margin: EdgeInsets.only(left: 12, right: 12, bottom: 12 + bottomInset),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F2023) : const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(22),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.92),
                    fontSize: 15,
                    fontWeight: AppFontWeights.emphasis,
                  ),
                ),
              ),
              IosIconButton(
                icon: Lucide.X,
                size: 18,
                padding: const EdgeInsets.all(7),
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.options.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        l10n.statsPageFilterNoOptions,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                  for (final option in widget.options)
                    _CheckRow(
                      label: option.label,
                      checked: _selected.contains(option.id),
                      onTap: () {
                        setState(() {
                          if (_selected.contains(option.id)) {
                            _selected.remove(option.id);
                          } else {
                            _selected.add(option.id);
                          }
                        });
                      },
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: IosCardPress(
                  onTap: () => setState(() => _selected.clear()),
                  borderRadius: BorderRadius.circular(13),
                  baseColor: isDark
                      ? cs.onSurface.withValues(alpha: 0.08)
                      : const Color(0xFFE7E9EC),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  child: Center(
                    child: Text(
                      l10n.statsPageFilterClear,
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.74),
                        fontSize: 13,
                        fontWeight: AppFontWeights.emphasis,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: IosCardPress(
                  onTap: () =>
                      Navigator.of(context).pop(Set.of(_selected)),
                  borderRadius: BorderRadius.circular(13),
                  baseColor: isDark
                      ? Colors.white.withValues(alpha: 0.16)
                      : const Color(0xFFDADDE2), // color-gate: ignore
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  child: Center(
                    child: Text(
                      l10n.statsPageFilterDone,
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.9),
                        fontSize: 13,
                        fontWeight: AppFontWeights.heavy,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
