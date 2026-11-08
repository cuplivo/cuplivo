import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models/assistant.dart';
import '../core/models/model_spec.dart';
import '../core/providers/settings_provider.dart';
import '../core/services/api/reasoning/reasoning_level_options.dart';
import '../core/services/model_spec/model_spec_resolver.dart';
import '../features/chat/widgets/reasoning_level_sheet.dart';
import '../features/group_chat/widgets/group_member_strip.dart';
import '../icons/lucide_adapter.dart';
import '../icons/reasoning_icons.dart';
import '../l10n/app_localizations.dart';
import '../shared/dialogs/reasoning_budget_custom_dialog.dart';
import 'desktop_glass_popover.dart';

Future<void> showDesktopReasoningLevelPopover(
  BuildContext context, {
  required GlobalKey anchorKey,
  required ProviderConfig config,
  required String modelId,
  Assistant? assistant,
  List<Assistant>? members,
}) async {
  final keyContext = anchorKey.currentContext;
  if (keyContext == null) return;

  final box = keyContext.findRenderObject() as RenderBox?;
  if (box == null) return;
  final offset = box.localToGlobal(Offset.zero);
  final size = box.size;
  final anchorRect = Rect.fromLTWH(
    offset.dx,
    offset.dy,
    size.width,
    size.height,
  );

  return showDesktopGlassPopover(
    context,
    anchorRect: anchorRect,
    width: (size.width - 16).clamp(260.0, 720.0),
    builder: (ctx, handle) {
      final roster = members;
      if (roster != null && roster.length > 1) {
        return _GroupReasoningPopover(
          members: roster,
          initialId: assistant?.id,
          onDone: handle.close,
          onSuspendedChanged: handle.setSuspended,
        );
      }
      return _ReasoningContent(
        onDone: handle.close,
        onSuspendedChanged: handle.setSuspended,
        config: config,
        modelId: modelId,
        assistant: assistant,
      );
    },
  );
}

/// The popover, scoped to one member of a group: the strip picks whose level
/// the tiles below commit, and each member resolves its own model.
class _GroupReasoningPopover extends StatefulWidget {
  const _GroupReasoningPopover({
    required this.members,
    required this.onDone,
    required this.onSuspendedChanged,
    this.initialId,
  });

  final List<Assistant> members;
  final String? initialId;
  final Future<void> Function() onDone;
  final ValueChanged<bool> onSuspendedChanged;

  @override
  State<_GroupReasoningPopover> createState() => _GroupReasoningPopoverState();
}

class _GroupReasoningPopoverState extends State<_GroupReasoningPopover> {
  late String _selectedId = widget.initialId ?? widget.members.first.id;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsProvider>();
    final byId = {for (final member in widget.members) member.id: member};
    final member = byId[_selectedId] ?? widget.members.first;
    final providerKey =
        member.chatModelProvider ?? settings.currentModelProvider;
    final modelId = member.chatModelId ?? settings.currentModelId;
    final hasModel = providerKey != null && (modelId ?? '').isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: GroupMemberStrip(
            members: widget.members,
            selectedId: member.id,
            onSelect: (picked) => setState(() => _selectedId = picked.id),
          ),
        ),
        if (hasModel)
          _ReasoningContent(
            onDone: widget.onDone,
            onSuspendedChanged: widget.onSuspendedChanged,
            config: settings.getProviderConfig(providerKey),
            modelId: modelId!,
            assistant: member,
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Text(
              l10n.reasoningLevelNoReasoning,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.62),
                decoration: TextDecoration.none,
              ),
            ),
          ),
      ],
    );
  }
}

class _ReasoningContent extends StatelessWidget {
  const _ReasoningContent({
    required this.onDone,
    required this.onSuspendedChanged,
    required this.config,
    required this.modelId,
    this.assistant,
  });

  final Future<void> Function() onDone;
  final ValueChanged<bool> onSuspendedChanged;
  final ProviderConfig config;
  final String modelId;
  final Assistant? assistant;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsProvider>();
    final spec = ModelSpecResolver.instance.spec(config, modelId);
    if (!spec.supportsReasoning) {
      return Padding(
        key: const ValueKey('reasoning-unsupported'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Text(
          l10n.reasoningLevelNoReasoning,
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.62),
            decoration: TextDecoration.none,
          ),
        ),
      );
    }
    final snapshot = buildReasoningLevelPickerSnapshot(
      settings: settings,
      config: config,
      modelId: modelId,
      spec: spec,
      assistant: assistant,
    );
    final stops = snapshot.sliderStops;

    Widget tile({
      required Key key,
      required Widget Function(Color color) leadingBuilder,
      required String label,
      required bool selected,
      Widget? trailing,
      required VoidCallback onTap,
    }) {
      final cs = Theme.of(context).colorScheme;
      final onColor = selected ? cs.primary : cs.onSurface;
      final iconColor = selected ? cs.primary : cs.onSurface;
      return Padding(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
        child: _HoverRow(
          leading: leadingBuilder(iconColor),
          label: label,
          selected: selected,
          trailing: trailing,
          onTap: onTap,
          labelStyle: TextStyle(
            fontSize: 13,
            fontWeight: AppFontWeights.regular,
            decoration: TextDecoration.none,
          ).copyWith(color: onColor),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(0, 10, 0, 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final stop in stops)
              tile(
                key: ValueKey(stop.key),
                leadingBuilder: (c) => ReasoningIcons.levelIcon(
                  stop.level ?? ReasoningLevel.auto,
                  size: 16,
                  color: c,
                ),
                label: reasoningLevelLabel(
                  l10n,
                  stop.level ?? ReasoningLevel.auto,
                ),
                selected: snapshot.isSelected(stop),
                onTap: () async {
                  final request = stop.request;
                  if (request == null) return;
                  await commitReasoningChoice(
                    context.read<SettingsProvider>(),
                    config,
                    modelId,
                    assistant,
                    request,
                  );
                  if (!context.mounted) return;
                  await onDone();
                },
              ),
            if (snapshot.isBudgetStyle)
              tile(
                key: const ValueKey('reasoning-row-custom'),
                leadingBuilder: (c) => Icon(Lucide.Hash, size: 16, color: c),
                label: l10n.reasoningLevelCustomBudget,
                selected: snapshot.customSelected,
                trailing: snapshot.customSelected
                    ? Text(
                        (snapshot.selected.budgetTokens ?? 0).toString(),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: AppFontWeights.semibold,
                          color: Theme.of(context).colorScheme.primary,
                          decoration: TextDecoration.none,
                        ),
                      )
                    : Icon(
                        Lucide.ChevronRight,
                        size: 16,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.45),
                      ),
                onTap: () async {
                  final initialValue = snapshot.customSelected
                      ? (snapshot.selected.budgetTokens ?? 2048)
                      : 2048;
                  onSuspendedChanged(true);
                  var restore = true;
                  try {
                    final chosen = await ReasoningBudgetCustomDialog.show(
                      context,
                      initialValue: initialValue,
                    );
                    if (!context.mounted) return;
                    if (chosen == null) return;
                    restore = false;
                    await commitReasoningChoice(
                      context.read<SettingsProvider>(),
                      config,
                      modelId,
                      assistant,
                      requestForCustomBudget(snapshot.spec, chosen),
                    );
                    if (!context.mounted) return;
                    await onDone();
                  } finally {
                    if (restore && context.mounted) {
                      onSuspendedChanged(false);
                    }
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _HoverRow extends StatefulWidget {
  const _HoverRow({
    required this.leading,
    required this.label,
    required this.selected,
    required this.onTap,
    this.trailing,
    this.labelStyle,
  });
  final Widget leading;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;
  final TextStyle? labelStyle;

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final baseBg = Colors.transparent;
    final hoverBg = cs.onSurface.withValues(alpha: isDark ? 0.12 : 0.10);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: _hovered ? hoverBg : baseBg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: Center(child: widget.leading),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      widget.labelStyle ??
                      TextStyle(
                        fontSize: 13,
                        fontWeight: AppFontWeights.regular,
                        decoration: TextDecoration.none,
                      ),
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 8),
                widget.trailing!,
              ],
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                child: widget.selected
                    ? Icon(
                        Lucide.Check,
                        key: const ValueKey('check'),
                        size: 16,
                        color: cs.primary,
                      )
                    : const SizedBox(width: 16, key: ValueKey('space')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
