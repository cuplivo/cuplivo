import 'package:flutter/material.dart';

import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';
import 'package:Cuplivo/features/harness/widgets/chat/dsh_picker_scaffold.dart';
import 'package:Cuplivo/features/home/widgets/model_icon.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/shared/widgets/section_card.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

/// Opens the remote model picker and returns the choice, or null when the user
/// dismissed it.
///
/// The picker is driven only by [catalog] — the Host's `session/modelCatalog`
/// — never by Cuplivo's local provider settings. Selecting a model keeps the
/// session's current reasoning effort when the new model still advertises it,
/// otherwise the model's catalog default is used; the reasoning picker is a
/// separate control, exactly as in DSH.
Future<DshModelSelection?> showDshModelPicker(
  BuildContext context, {
  required DshModelCatalog catalog,
  DshModelSelection? current,
  Key? panelKey,
}) {
  return showDshPicker<DshModelSelection>(
    context: context,
    title: AppLocalizations.of(context)!.dshModelPickerTitle,
    panelKey: panelKey,
    bodyBuilder: (context, scrollController) => DshModelPicker(
      catalog: catalog,
      current: current,
      scrollController: scrollController,
    ),
  );
}

/// Mobile sheet / desktop dialog body: search, provider pills and the model
/// rows grouped by provider.
class DshModelPicker extends StatefulWidget {
  const DshModelPicker({
    super.key,
    required this.catalog,
    required this.scrollController,
    this.current,
  });

  final DshModelCatalog catalog;
  final DshModelSelection? current;
  final ScrollController scrollController;

  static const searchFieldKey = ValueKey<String>('dsh-model-search');
  static Key rowKey(String providerId, String modelId) =>
      ValueKey<String>('dsh-model-row-$providerId::$modelId');

  @override
  State<DshModelPicker> createState() => _DshModelPickerState();
}

class _DshModelPickerState extends State<DshModelPicker> {
  final TextEditingController _search = TextEditingController();

  /// Provider id whose section is shown, or null for the whole catalog.
  String? _providerFilter;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get _query => _search.text.trim().toLowerCase();

  bool _matchesModel(DshModelOption model) {
    if (_query.isEmpty) return true;
    return model.displayName.toLowerCase().contains(_query) ||
        model.id.toLowerCase().contains(_query) ||
        (model.description ?? '').toLowerCase().contains(_query);
  }

  bool _matchesGroup(DshModelProviderGroup group) {
    if (_query.isEmpty) return true;
    return group.displayName.toLowerCase().contains(_query) ||
        group.id.toLowerCase().contains(_query);
  }

  List<DshModelProviderGroup> _visibleGroups() {
    final groups = widget.catalog.groups
        .where((group) {
          if (_providerFilter != null && group.id != _providerFilter) {
            return false;
          }
          if (group.models.isEmpty) return false;
          return _matchesGroup(group) || group.models.any(_matchesModel);
        })
        .toList(growable: false);
    return groups;
  }

  DshModelSelection _selectionFor(
    DshModelProviderGroup group,
    DshModelOption model,
  ) {
    final effort = model.supportsReasoning
        ? model.resolveEffort(widget.current?.reasoningEffortId)?.id
        : null;
    return DshModelSelection(
      providerId: group.id,
      modelId: model.id,
      reasoningEffortId: effort,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final groups = _visibleGroups();
    final groupsWithModels = widget.catalog.groups
        .where((group) => group.models.isNotEmpty)
        .toList(growable: false);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            key: DshModelPicker.searchFieldKey,
            controller: _search,
            onChanged: (_) => setState(() {}),
            style: TextStyle(color: cs.onSurface, fontSize: 14),
            cursorColor: cs.primary,
            decoration: InputDecoration(
              hintText: l10n.dshModelPickerSearchHint,
              isDense: true,
              filled: true,
              fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.5),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 11,
              ),
              prefixIcon: Icon(
                Lucide.Search,
                size: 17,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: cs.primary.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
        ),
        if (groupsWithModels.length > 1)
          _ProviderPills(
            groups: groupsWithModels,
            selected: _providerFilter,
            onSelected: (value) => setState(() => _providerFilter = value),
          ),
        Expanded(
          child: widget.catalog.isLoading && widget.catalog.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  controller: widget.scrollController,
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    if (groups.isEmpty && widget.catalog.failures.isEmpty)
                      DshPickerEmptyState(
                        icon: Lucide.Boxes,
                        message: l10n.dshModelPickerEmpty,
                      ),
                    for (final group in groups) ...[
                      DshPickerSectionHeader(
                        title: group.displayName,
                        trailing: Text(
                          '${group.models.where(_matchesModel).length}',
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withValues(alpha: 0.45),
                          ),
                        ),
                      ),
                      for (final model in group.models.where(_matchesModel))
                        _DshModelRow(
                          key: DshModelPicker.rowKey(group.id, model.id),
                          group: group,
                          model: model,
                          selected:
                              widget.current?.providerId == group.id &&
                              widget.current?.modelId == model.id,
                          onTap: () => Navigator.of(
                            context,
                          ).pop(_selectionFor(group, model)),
                        ),
                    ],
                    if (_query.isEmpty &&
                        widget.catalog.failures.isNotEmpty) ...[
                      DshPickerSectionHeader(
                        title: l10n.dshModelPickerFailuresSection,
                      ),
                      for (final failure in widget.catalog.failures)
                        _DshFailureRow(failure: failure),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _ProviderPills extends StatelessWidget {
  const _ProviderPills({
    required this.groups,
    required this.selected,
    required this.onSelected,
  });

  final List<DshModelProviderGroup> groups;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        children: [
          _DshProviderPill(
            key: const ValueKey<String>('dsh-model-provider-all'),
            label: l10n.dshModelPickerAllProviders,
            selected: selected == null,
            onTap: () => onSelected(null),
          ),
          for (final group in groups)
            _DshProviderPill(
              key: ValueKey<String>('dsh-model-provider-${group.id}'),
              label: group.displayName,
              selected: selected == group.id,
              onTap: () => onSelected(group.id),
            ),
        ],
      ),
    );
  }
}

class _DshProviderPill extends StatelessWidget {
  const _DshProviderPill({
    super.key,
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? (isDark
                      ? cs.primary.withValues(alpha: 0.14)
                      : cs.primary.withValues(alpha: 0.10))
                : sheetTileColor(context),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? cs.primary.withValues(alpha: 0.45)
                  : cs.outlineVariant.withValues(alpha: 0.25),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected
                  ? AppFontWeights.semibold
                  : AppFontWeights.medium,
              color: selected ? cs.primary : cs.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _DshModelRow extends StatelessWidget {
  const _DshModelRow({
    super.key,
    required this.group,
    required this.model,
    required this.selected,
    required this.onTap,
  });

  final DshModelProviderGroup group;
  final DshModelOption model;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = selected
        ? (isDark
              ? cs.primary.withValues(alpha: 0.12)
              : cs.primary.withValues(alpha: 0.08))
        : sheetTileColor(context);
    final badges = <Widget>[
      if ((model.badge ?? '').trim().isNotEmpty)
        _DshTag(label: model.badge!.trim()),
      if (model.supportsReasoning)
        _DshTag(
          label:
              model.defaultEffort?.name ??
              AppLocalizations.of(context)!.dshModelReasoningBadge,
          icon: Lucide.Brain,
          accent: true,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: RepaintBoundary(
        child: IosCardPress(
          baseColor: bg,
          borderRadius: BorderRadius.circular(14),
          pressedBlendStrength: 0.10,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          onTap: onTap,
          child: Row(
            children: [
              CurrentModelIcon(
                providerKey: group.id,
                modelId: model.id,
                size: 28,
                iconScale: 0.62,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: AppFontWeights.semibold,
                        color: cs.onSurface,
                      ),
                    ),
                    if ((model.description ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        model.description!.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.25,
                          color: cs.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                    if (badges.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 4, children: badges),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (selected)
                Icon(Lucide.Check, size: 18, color: cs.primary)
              else
                const SizedBox(width: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _DshFailureRow extends StatelessWidget {
  const _DshFailureRow({required this.failure});

  final DshModelCatalogFailure failure;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Container(
        key: ValueKey<String>('dsh-model-failure-${failure.id}'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: sheetTileColor(context),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(
              Lucide.TriangleAlert,
              size: 20,
              color: cs.onSurface.withValues(alpha: 0.4),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    failure.name.trim().isEmpty ? failure.id : failure.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: AppFontWeights.medium,
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                  if ((failure.message ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      failure.message!.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.45),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DshTag extends StatelessWidget {
  const _DshTag({required this.label, this.icon, this.accent = false});

  final String label;
  final IconData? icon;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = accent ? cs.primary : cs.onSurface.withValues(alpha: 0.55);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: AppFontWeights.medium,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
