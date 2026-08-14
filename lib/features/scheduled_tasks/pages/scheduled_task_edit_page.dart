import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../../../core/models/scheduled_task.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/scheduled_task_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

class ScheduledTaskEditPage extends StatefulWidget {
  const ScheduledTaskEditPage({super.key, this.taskId});

  final String? taskId;

  @override
  State<ScheduledTaskEditPage> createState() => _ScheduledTaskEditPageState();
}

class _ScheduledTaskEditPageState extends State<ScheduledTaskEditPage> {
  final _nameController = TextEditingController();
  final _promptController = TextEditingController();
  final _intervalController = TextEditingController(text: '1');
  String? _assistantId;
  ScheduledTaskFrequency _frequency = ScheduledTaskFrequency.daily;
  DateTime _anchorDate = DateTime.now();
  DateTime _onceAt = DateTime.now().add(const Duration(hours: 1));
  TimeOfDay _time = const TimeOfDay(hour: 8, minute: 0);
  final Set<int> _weekdays = <int>{DateTime.monday};
  final Set<int> _monthDays = <int>{1};
  int _yearMonth = 1;
  int _yearDay = 1;
  bool _initialized = false;
  bool _saving = false;

  ScheduledTask? get _task => widget.taskId == null
      ? null
      : context.read<ScheduledTaskProvider>().getById(widget.taskId!);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final task = _task;
    final assistants = context.read<AssistantProvider>().assistants;
    if (task == null) {
      _assistantId = assistants.isEmpty ? null : assistants.first.id;
      _yearMonth = _anchorDate.month;
      _yearDay = _anchorDate.day;
      _monthDays
        ..clear()
        ..add(_anchorDate.day);
      _weekdays
        ..clear()
        ..add(_anchorDate.weekday);
      return;
    }

    final schedule = task.schedule.normalized();
    _nameController.text = task.name;
    _promptController.text = task.prompt;
    _assistantId = task.assistantId;
    _frequency = schedule.frequency;
    _intervalController.text = schedule.interval.toString();
    _anchorDate = schedule.anchorDate ?? task.createdAt;
    _time = TimeOfDay(hour: schedule.hour, minute: schedule.minute);
    _onceAt = schedule.onceAt ?? _anchorDate;
    _weekdays
      ..clear()
      ..addAll(
        schedule.weekdays.isEmpty
            ? <int>[_anchorDate.weekday]
            : schedule.weekdays,
      );
    _monthDays
      ..clear()
      ..addAll(
        schedule.monthDays.isEmpty
            ? <int>[_anchorDate.day]
            : schedule.monthDays,
      );
    _yearMonth = schedule.yearMonth ?? _anchorDate.month;
    _yearDay = schedule.yearDay ?? _anchorDate.day;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _promptController.dispose();
    _intervalController.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final value = await showTimePicker(context: context, initialTime: _time);
    if (value != null && mounted) setState(() => _time = value);
  }

  Future<void> _pickAnchorDate() async {
    final value = await showDatePicker(
      context: context,
      initialDate: _anchorDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (value != null && mounted) setState(() => _anchorDate = value);
  }

  Future<void> _pickOnceDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _onceAt,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_onceAt),
    );
    if (time == null || !mounted) return;
    setState(() {
      _onceAt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
      _time = time;
    });
  }

  Future<void> _pickYearDate() async {
    final initial = DateTime(
      2024,
      _yearMonth,
      _validDayForMonth(2024, _yearMonth, _yearDay),
    );
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2024),
      lastDate: DateTime(2024, 12, 31),
    );
    if (date != null && mounted) {
      setState(() {
        _yearMonth = date.month;
        _yearDay = date.day;
      });
    }
  }

  ScheduledTaskSchedule _buildSchedule() {
    final interval = int.tryParse(_intervalController.text.trim()) ?? 1;
    return ScheduledTaskSchedule(
      frequency: _frequency,
      interval: interval,
      hour: _frequency == ScheduledTaskFrequency.once ? _onceAt.hour : _time.hour,
      minute:
          _frequency == ScheduledTaskFrequency.once ? _onceAt.minute : _time.minute,
      anchorDate: _anchorDate,
      weekdays: _weekdays.toList()..sort(),
      monthDays: _monthDays.toList()..sort(),
      yearMonth: _yearMonth,
      yearDay: _yearDay,
      onceAt: _frequency == ScheduledTaskFrequency.once ? _onceAt : null,
    ).normalized();
  }

  Future<void> _save() async {
    if (_saving) return;
    final l10n = AppLocalizations.of(context)!;
    final name = _nameController.text.trim();
    final prompt = _promptController.text.trim();
    final interval = int.tryParse(_intervalController.text.trim()) ?? 0;
    if (_assistantId == null || name.isEmpty || prompt.isEmpty || interval < 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.scheduledTaskInvalidForm)),
      );
      return;
    }
    if (_frequency == ScheduledTaskFrequency.weekly && _weekdays.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.scheduledTaskSelectWeekday)),
      );
      return;
    }
    if (_frequency == ScheduledTaskFrequency.monthly && _monthDays.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.scheduledTaskSelectMonthDay)),
      );
      return;
    }

    setState(() => _saving = true);
    final provider = context.read<ScheduledTaskProvider>();
    try {
      if (widget.taskId == null) {
        await provider.createTask(
          assistantId: _assistantId!,
          name: name,
          prompt: prompt,
          schedule: _buildSchedule(),
        );
      } else {
        await provider.updateTask(
          id: widget.taskId!,
          assistantId: _assistantId!,
          name: name,
          prompt: prompt,
          schedule: _buildSchedule(),
        );
      }
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final task = _task;
    if (task == null) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.scheduledTaskDeleteTitle),
        content: Text(l10n.scheduledTaskDeleteMessage),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.scheduledTaskCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              l10n.scheduledTaskDelete,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<ScheduledTaskProvider>().deleteTask(task.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final assistants = context.watch<AssistantProvider>().assistants;
    final task = widget.taskId == null
        ? null
        : context.watch<ScheduledTaskProvider>().getById(widget.taskId!);
    if (widget.taskId != null && task == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.scheduledTaskEdit)),
        body: Center(child: Text(l10n.scheduledTaskNotFound)),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.taskId == null
              ? l10n.scheduledTaskCreate
              : l10n.scheduledTaskEdit,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(l10n.scheduledTaskSave),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: l10n.scheduledTaskName,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: assistants.any((a) => a.id == _assistantId)
                ? _assistantId
                : null,
            decoration: InputDecoration(
              labelText: l10n.scheduledTaskAssistant,
              border: const OutlineInputBorder(),
            ),
            items: assistants
                .map(
                  (assistant) => DropdownMenuItem<String>(
                    value: assistant.id,
                    child: Text(assistant.name),
                  ),
                )
                .toList(growable: false),
            onChanged: (value) => setState(() => _assistantId = value),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _promptController,
            minLines: 5,
            maxLines: 10,
            decoration: InputDecoration(
              labelText: l10n.scheduledTaskPrompt,
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 18),
          DropdownButtonFormField<ScheduledTaskFrequency>(
            initialValue: _frequency,
            decoration: InputDecoration(
              labelText: l10n.scheduledTaskFrequency,
              border: const OutlineInputBorder(),
            ),
            items: ScheduledTaskFrequency.values
                .map(
                  (frequency) => DropdownMenuItem<ScheduledTaskFrequency>(
                    value: frequency,
                    child: Text(_frequencyLabel(l10n, frequency)),
                  ),
                )
                .toList(growable: false),
            onChanged: (value) {
              if (value != null) setState(() => _frequency = value);
            },
          ),
          if (_frequency != ScheduledTaskFrequency.once) ...<Widget>[
            const SizedBox(height: 12),
            TextField(
              controller: _intervalController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: l10n.scheduledTaskInterval,
                helperText: _intervalHelper(l10n),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            _PickerTile(
              icon: Lucide.Calendar,
              title: l10n.scheduledTaskStartDate,
              value: MaterialLocalizations.of(context).formatMediumDate(
                _anchorDate,
              ),
              onTap: _pickAnchorDate,
            ),
          ],
          const SizedBox(height: 12),
          if (_frequency == ScheduledTaskFrequency.once)
            _PickerTile(
              icon: Lucide.Calendar,
              title: l10n.scheduledTaskRunOnceAt,
              value:
                  '${MaterialLocalizations.of(context).formatMediumDate(_onceAt)} · ${TimeOfDay.fromDateTime(_onceAt).format(context)}',
              onTap: _pickOnceDate,
            )
          else
            _PickerTile(
              icon: Lucide.Timer,
              title: l10n.scheduledTaskTime,
              value: _time.format(context),
              onTap: _pickTime,
            ),
          if (_frequency == ScheduledTaskFrequency.weekly) ...<Widget>[
            const SizedBox(height: 16),
            Text(l10n.scheduledTaskWeekdays),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: List<Widget>.generate(7, (index) {
                final weekday = index + 1;
                final narrow = MaterialLocalizations.of(context).narrowWeekdays;
                final label = narrow[weekday == DateTime.sunday ? 0 : weekday];
                return FilterChip(
                  label: Text(label),
                  selected: _weekdays.contains(weekday),
                  onSelected: (selected) {
                    setState(() {
                      if (selected) {
                        _weekdays.add(weekday);
                      } else {
                        _weekdays.remove(weekday);
                      }
                    });
                  },
                );
              }),
            ),
          ],
          if (_frequency == ScheduledTaskFrequency.monthly) ...<Widget>[
            const SizedBox(height: 16),
            Text(l10n.scheduledTaskMonthDaysLabel),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: List<Widget>.generate(31, (index) {
                final day = index + 1;
                return FilterChip(
                  label: Text(day.toString()),
                  selected: _monthDays.contains(day),
                  onSelected: (selected) {
                    setState(() {
                      if (selected) {
                        _monthDays.add(day);
                      } else {
                        _monthDays.remove(day);
                      }
                    });
                  },
                );
              }),
            ),
          ],
          if (_frequency == ScheduledTaskFrequency.yearly) ...<Widget>[
            const SizedBox(height: 12),
            _PickerTile(
              icon: Lucide.Calendar,
              title: l10n.scheduledTaskYearDate,
              value: DateFormat.MMMd(
                Localizations.localeOf(context).toString(),
              ).format(
                DateTime(
                  2024,
                  _yearMonth,
                  _validDayForMonth(2024, _yearMonth, _yearDay),
                ),
              ),
              onTap: _pickYearDate,
            ),
          ],
          const SizedBox(height: 14),
          Text(
            l10n.scheduledTaskTimezoneNote,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.6),
            ),
          ),
          if (widget.taskId != null) ...<Widget>[
            const SizedBox(height: 28),
            OutlinedButton.icon(
              onPressed: _delete,
              icon: const Icon(Lucide.Trash2),
              label: Text(l10n.scheduledTaskDelete),
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _intervalHelper(AppLocalizations l10n) {
    switch (_frequency) {
      case ScheduledTaskFrequency.daily:
        return l10n.scheduledTaskIntervalDayHelp;
      case ScheduledTaskFrequency.weekly:
        return l10n.scheduledTaskIntervalWeekHelp;
      case ScheduledTaskFrequency.monthly:
        return l10n.scheduledTaskIntervalMonthHelp;
      case ScheduledTaskFrequency.yearly:
        return l10n.scheduledTaskIntervalYearHelp;
      case ScheduledTaskFrequency.once:
        return '';
    }
  }
}

class _PickerTile extends StatelessWidget {
  const _PickerTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(value),
        trailing: const Icon(Lucide.ChevronRight, size: 18),
        onTap: onTap,
      ),
    );
  }
}

String _frequencyLabel(
  AppLocalizations l10n,
  ScheduledTaskFrequency frequency,
) {
  switch (frequency) {
    case ScheduledTaskFrequency.once:
      return l10n.scheduledTaskFrequencyOnce;
    case ScheduledTaskFrequency.daily:
      return l10n.scheduledTaskFrequencyDaily;
    case ScheduledTaskFrequency.weekly:
      return l10n.scheduledTaskFrequencyWeekly;
    case ScheduledTaskFrequency.monthly:
      return l10n.scheduledTaskFrequencyMonthly;
    case ScheduledTaskFrequency.yearly:
      return l10n.scheduledTaskFrequencyYearly;
  }
}

int _validDayForMonth(int year, int month, int day) {
  final lastDay = DateTime(year, month + 1, 0).day;
  return day.clamp(1, lastDay).toInt();
}
