import 'package:flutter/material.dart';

import 'package:Cuplivo/features/stats/models/stats_models.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

/// Stats filter dialog: three dimensions (models, assistants, topics), each
/// an OR set; dimensions combine with AND. Dialog — desktop safe.
class StatsFilterDialog extends StatefulWidget {
  const StatsFilterDialog({
    super.key,
    required this.filter,
    required this.assistantOptions,
    required this.modelIds,
    required this.topicOptions,
    required this.defaultAssistantLabel,
  });

  final StatsFilter filter;
  final List<(String, String)> assistantOptions;
  final List<String> modelIds;
  final List<(String, String)> topicOptions;
  final String defaultAssistantLabel;

  @override
  State<StatsFilterDialog> createState() => _StatsFilterDialogState();
}

class _StatsFilterDialogState extends State<StatsFilterDialog> {
  late final Set<String> _modelIds;
  late final Set<String> _assistantIds;
  late final Set<String> _topicIds;

  @override
  void initState() {
    super.initState();
    _modelIds = {...widget.filter.modelIds};
    _assistantIds = {...widget.filter.assistantIds};
    _topicIds = {...widget.filter.topicIds};
  }

  void _toggle(Set<String> set, String id) =>
      setState(() => set.contains(id) ? set.remove(id) : set.add(id));

  Widget _section(String title, {required List<Widget> children}) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ),
        ...children,
      ],
    );
  }

  Widget _row({
    required String label,
    required bool checked,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            Icon(
              checked ? Lucide.CircleCheck : Lucide.Circle,
              size: 18,
              color: checked ? cs.primary : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: cs.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: cs.surface,
      title: Text(l10n.statsPageFilterTitle),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _section(
                l10n.statsPageFilterAssistants,
                children: widget.assistantOptions.isEmpty
                    ? [_emptyHint(l10n.statsPageFilterNoOptions)]
                    : [
                        for (final (id, name) in widget.assistantOptions)
                          _row(
                            label: name,
                            checked: _assistantIds.contains(id),
                            onTap: () => _toggle(_assistantIds, id),
                          ),
                      ],
              ),
              _section(
                l10n.statsPageFilterModels,
                children: widget.modelIds.isEmpty
                    ? [_emptyHint(l10n.statsPageFilterNoOptions)]
                    : [
                        for (final id in widget.modelIds)
                          _row(
                            label: id,
                            checked: _modelIds.contains(id),
                            onTap: () => _toggle(_modelIds, id),
                          ),
                      ],
              ),
              _section(
                l10n.statsPageFilterTopics,
                children: widget.topicOptions.isEmpty
                    ? [_emptyHint(l10n.statsPageFilterNoOptions)]
                    : [
                        for (final (id, title) in widget.topicOptions)
                          _row(
                            label: title,
                            checked: _topicIds.contains(id),
                            onTap: () => _toggle(_topicIds, id),
                          ),
                      ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(const StatsFilter()),
          child: Text(l10n.statsPageFilterClearAll),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.statsPageFilterClear),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            StatsFilter(
              modelIds: _modelIds,
              assistantIds: _assistantIds,
              topicIds: _topicIds,
            ),
          ),
          child: Text(l10n.statsPageFilterDone),
        ),
      ],
    );
  }

  Widget _emptyHint(String label) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
    );
  }
}
