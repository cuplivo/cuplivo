import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/models/scheduled_task.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/scheduled_task_provider.dart';
import '../../../core/services/scheduled_tasks/ios_scheduled_task_bridge.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import 'scheduled_task_edit_page.dart';
import 'scheduled_task_logs_page.dart';

class ScheduledTasksPage extends StatelessWidget {
  const ScheduledTasksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<ScheduledTaskProvider>();
    final assistants = context.watch<AssistantProvider>();

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.scheduledTaskPageTitle),
        actions: <Widget>[
          IconButton(
            tooltip: l10n.scheduledTaskCreate,
            icon: const Icon(Lucide.Plus),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ScheduledTaskEditPage(),
              ),
            ),
          ),
        ],
      ),
      body: provider.isLoaded
          ? ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: <Widget>[
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(
                    children: <Widget>[
                      SwitchListTile.adaptive(
                        secondary: const Icon(Lucide.Bot),
                        title: Text(l10n.scheduledTaskAllowAi),
                        subtitle: Text(l10n.scheduledTaskAllowAiSubtitle),
                        value: provider.allowAiOperations,
                        onChanged: provider.setAllowAiOperations,
                      ),
                      const Divider(height: 1),
                      SwitchListTile.adaptive(
                        secondary: const Icon(Lucide.Shield),
                        title: Text(l10n.scheduledTaskRequireApproval),
                        subtitle: Text(
                          l10n.scheduledTaskRequireApprovalSubtitle,
                        ),
                        value: provider.aiRequiresApproval,
                        onChanged: provider.allowAiOperations
                            ? provider.setAiRequiresApproval
                            : null,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.scheduledTaskShortcutHelp,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.65),
                  ),
                ),
                const SizedBox(height: 16),
                if (provider.tasks.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 64),
                    child: Column(
                      children: <Widget>[
                        Icon(
                          Lucide.Timer,
                          size: 42,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.35),
                        ),
                        const SizedBox(height: 12),
                        Text(l10n.scheduledTaskEmpty),
                      ],
                    ),
                  )
                else
                  ...provider.tasks.map((task) {
                    final assistant = assistants.getById(task.assistantId);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _ScheduledTaskCard(
                        key: ValueKey<String>(task.id),
                        task: task,
                        assistantName:
                            assistant?.name ?? l10n.scheduledTaskUnknownAssistant,
                      ),
                    );
                  }),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}

class _ScheduledTaskCard extends StatefulWidget {
  const _ScheduledTaskCard({
    super.key,
    required this.task,
    required this.assistantName,
  });

  final ScheduledTask task;
  final String assistantName;

  @override
  State<_ScheduledTaskCard> createState() => _ScheduledTaskCardState();
}

class _ScheduledTaskCardState extends State<_ScheduledTaskCard> {
  bool _connecting = false;

  Future<void> _connect() async {
    if (_connecting) return;
    setState(() => _connecting = true);
    final provider = context.read<ScheduledTaskProvider>();
    await provider.markConnected(widget.task.id);
    if (mounted) {
      // Let AnimatedSwitcher show the compact connected state before iOS
      // transfers the user to Shortcuts.
      await Future<void>.delayed(const Duration(milliseconds: 180));
    }
    await IosScheduledTaskBridge.instance.openShortcutSetup(
      triggerId: widget.task.triggerId,
      taskName: widget.task.name,
    );
    if (mounted) setState(() => _connecting = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final task = widget.task;
    final cs = Theme.of(context).colorScheme;
    final muted = cs.onSurface.withValues(alpha: 0.55);
    final latest = task.logs.isEmpty ? null : task.logs.first;

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ScheduledTaskEditPage(taskId: task.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      task.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: task.isCompleted ? muted : cs.onSurface,
                        decoration:
                            task.isCompleted ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${widget.assistantName} · ${formatScheduledTaskSchedule(context, task.schedule)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                    if (task.isCompleted) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        l10n.scheduledTaskCompleted,
                        style: TextStyle(fontSize: 12, color: muted),
                      ),
                    ] else if (latest != null) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        latest.status == ScheduledTaskExecutionStatus.success
                            ? l10n.scheduledTaskLastSuccess(
                                _formatDateTime(context, latest.finishedAt),
                              )
                            : l10n.scheduledTaskLastFailure(
                                _formatDateTime(context, latest.finishedAt),
                              ),
                        style: TextStyle(fontSize: 12, color: muted),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: task.connected
                    ? l10n.scheduledTaskReconnect
                    : l10n.scheduledTaskConnect,
                child: TextButton(
                  onPressed: _connecting ? null : _connect,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(40, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: task.connected
                        ? const Icon(
                            Lucide.Link,
                            key: ValueKey<String>('connected'),
                            size: 19,
                          )
                        : Row(
                            key: const ValueKey<String>('connect'),
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              const Icon(Lucide.Link, size: 18),
                              const SizedBox(width: 4),
                              Text(l10n.scheduledTaskConnect),
                            ],
                          ),
                  ),
                ),
              ),
              IconButton(
                tooltip: l10n.scheduledTaskLogs,
                icon: const Icon(Lucide.History, size: 20),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ScheduledTaskLogsPage(taskId: task.id),
                  ),
                ),
              ),
              Switch.adaptive(
                value: task.enabled,
                onChanged: task.isCompleted
                    ? null
                    : (value) => context
                          .read<ScheduledTaskProvider>()
                          .setEnabled(task.id, value),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String formatScheduledTaskSchedule(
  BuildContext context,
  ScheduledTaskSchedule schedule,
) {
  final l10n = AppLocalizations.of(context)!;
  final s = schedule.normalized();
  final time = TimeOfDay(hour: s.hour, minute: s.minute).format(context);
  String frequency;
  switch (s.frequency) {
    case ScheduledTaskFrequency.once:
      final at = s.onceAt;
      if (at == null) return l10n.scheduledTaskFrequencyOnce;
      final locale = Localizations.localeOf(context).toString();
      return '${DateFormat.yMMMd(locale).format(at)} · ${TimeOfDay.fromDateTime(at).format(context)}';
    case ScheduledTaskFrequency.daily:
      frequency = s.interval == 1
          ? l10n.scheduledTaskFrequencyDaily
          : l10n.scheduledTaskEveryN(
              s.interval,
              l10n.scheduledTaskUnitDay,
            );
      break;
    case ScheduledTaskFrequency.weekly:
      frequency = s.interval == 1
          ? l10n.scheduledTaskFrequencyWeekly
          : l10n.scheduledTaskEveryN(
              s.interval,
              l10n.scheduledTaskUnitWeek,
            );
      final weekdays = _weekdayLabels(context, s.weekdays);
      if (weekdays.isNotEmpty) frequency = '$frequency · $weekdays';
      break;
    case ScheduledTaskFrequency.monthly:
      frequency = s.interval == 1
          ? l10n.scheduledTaskFrequencyMonthly
          : l10n.scheduledTaskEveryN(
              s.interval,
              l10n.scheduledTaskUnitMonth,
            );
      if (s.monthDays.isNotEmpty) {
        frequency = '$frequency · ${l10n.scheduledTaskMonthDays(s.monthDays.join(', '))}';
      }
      break;
    case ScheduledTaskFrequency.yearly:
      frequency = s.interval == 1
          ? l10n.scheduledTaskFrequencyYearly
          : l10n.scheduledTaskEveryN(
              s.interval,
              l10n.scheduledTaskUnitYear,
            );
      final date = DateTime(
        2024,
        s.yearMonth ?? 1,
        _validDayForMonth(2024, s.yearMonth ?? 1, s.yearDay ?? 1),
      );
      frequency =
          '$frequency · ${DateFormat.MMMd(Localizations.localeOf(context).toString()).format(date)}';
      break;
  }
  return '$frequency · $time';
}

String _weekdayLabels(BuildContext context, List<int> weekdays) {
  if (weekdays.isEmpty) return '';
  final labels = MaterialLocalizations.of(context).narrowWeekdays;
  return weekdays.map((weekday) {
    // narrowWeekdays begins with Sunday.
    final index = weekday == DateTime.sunday ? 0 : weekday;
    return labels[index];
  }).join(' ');
}

String _formatDateTime(BuildContext context, DateTime value) {
  final locale = Localizations.localeOf(context).toString();
  return '${DateFormat.Md(locale).format(value)} ${TimeOfDay.fromDateTime(value).format(context)}';
}

int _validDayForMonth(int year, int month, int day) {
  final lastDay = DateTime(year, month + 1, 0).day;
  return day.clamp(1, lastDay).toInt();
}
