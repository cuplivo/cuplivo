import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/models/scheduled_task.dart';
import '../../../core/providers/scheduled_task_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

class ScheduledTaskLogsPage extends StatelessWidget {
  const ScheduledTaskLogsPage({super.key, required this.taskId});

  final String taskId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final task = context.watch<ScheduledTaskProvider>().getById(taskId);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.scheduledTaskLogs)),
      body: task == null
          ? Center(child: Text(l10n.scheduledTaskNotFound))
          : task.logs.isEmpty
          ? Center(child: Text(l10n.scheduledTaskNoLogs))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: task.logs.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final log = task.logs[index];
                final success =
                    log.status == ScheduledTaskExecutionStatus.success;
                final locale = Localizations.localeOf(context).toString();
                final when =
                    '${DateFormat.yMMMd(locale).format(log.finishedAt)} ${TimeOfDay.fromDateTime(log.finishedAt).format(context)}';
                return Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: Icon(
                      success ? Lucide.CheckCircle : Lucide.CircleX,
                      color: success
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.error,
                    ),
                    title: Text(
                      success
                          ? l10n.scheduledTaskLogSuccess
                          : l10n.scheduledTaskLogFailure,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(when),
                        if (!success && (log.error?.isNotEmpty ?? false))
                          Text(
                            log.error!,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
