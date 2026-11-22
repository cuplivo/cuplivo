/// The 子代理 configuration: one line in the toolbox, three rows behind it.
///
/// The toolbox row is not a switch: it carries a summary of what delegations do
/// here (`继承本助手 · 深度 1`) and a chevron, and everything that can be decided
/// happens in the dialog it opens — 开启, 深度, 模型. A switch on the outer row
/// would have to sit beside a second level of configuration, and the accepted
/// round made the outer row a summary instead.
///
/// A phone gets a sheet and a desktop gets a dialog: the repo never puts a bottom
/// sheet on a desktop window, whatever its width.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../utils/platform_utils.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../home/services/local_tools_service.dart';
import '../../model/widgets/model_select_sheet.dart';
import '../services/subagent_model.dart';
import '../services/subagent_rules.dart' show kMaxSubagentDepth;

/// The toolbox row's second line: what a delegation would run on, and how deep it
/// may go.
String subagentSummary(AppLocalizations l10n, Assistant assistant) {
  final model =
      resolveSubagentModel(assistant)?.modelId ??
      l10n.subagentConfigModelInherit;
  return l10n.subagentConfigSummary(model, kMaxSubagentDepth);
}

/// Opens the configuration for delegating with [assistantId].
///
/// A desktop gets a dialog and a phone gets a sheet. The test is the platform,
/// not the window width: the repo never puts a bottom sheet on desktop, and a
/// narrow desktop window is still a desktop.
Future<void> showSubagentConfig(
  BuildContext context, {
  required String assistantId,
}) {
  final body = _SubagentConfigBody(assistantId: assistantId);
  if (PlatformUtils.isDesktop) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: body,
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => SafeArea(child: body),
  );
}

class _SubagentConfigBody extends StatelessWidget {
  const _SubagentConfigBody({required this.assistantId});

  final String assistantId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final assistant = context.select<AssistantProvider, Assistant?>(
      (provider) => provider.getById(assistantId),
    );
    if (assistant == null) return const SizedBox.shrink();
    final enabled = assistant.localToolIds.contains(LocalToolNames.delegate);
    final model = resolveSubagentModel(assistant);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.assistantEditLocalToolDelegateTitle,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.subagentConfigSubtitle,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: cs.onSurface.withValues(alpha: .6),
            ),
          ),
          const SizedBox(height: 8),
          _ConfigRow(
            label: l10n.subagentConfigEnabled,
            trailing: IosSwitch(
              value: enabled,
              semanticLabel: l10n.subagentConfigEnabled,
              onChanged: (value) => _setEnabled(context, assistant, value),
            ),
          ),
          // Depth is a number this build cannot change yet: nesting past one
          // level is still open, so the row states the value instead of offering
          // a picker with a single choice.
          _ConfigRow(
            label: l10n.subagentConfigDepth,
            description: l10n.subagentConfigDepthDescription,
            value: '$kMaxSubagentDepth',
          ),
          _ConfigRow(
            label: l10n.subagentConfigModel,
            description: l10n.subagentConfigModelDescription,
            value: model?.modelId ?? l10n.subagentConfigModelInherit,
            onTap: () => _pickModel(context, assistant),
          ),
          _ConfigRow(
            label: l10n.subagentEscalation,
            value: _escalationLabel(l10n, assistant.subagentEscalation),
            onTap: () => _pickEscalation(context, assistant),
          ),
        ],
      ),
    );
  }

  static String _escalationLabel(
    AppLocalizations l10n,
    SubagentEscalation value,
  ) => switch (value) {
    SubagentEscalation.ask => l10n.subagentEscalationAsk,
    SubagentEscalation.deny => l10n.subagentEscalationDeny,
    SubagentEscalation.allow => l10n.subagentEscalationAllow,
  };

  /// The three choices, each with the icon that carries its meaning: a question
  /// mark for asking, a prohibition for refusing, a warning for the one that
  /// spends the user's permission without asking.
  static Future<void> _pickEscalation(
    BuildContext context,
    Assistant assistant,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final assistants = context.read<AssistantProvider>();
    final current = assistant.subagentEscalation;
    final rows = <(SubagentEscalation, IconData, String)>[
      (
        SubagentEscalation.ask,
        Lucide.MessageCircleQuestionMark,
        l10n.subagentEscalationAsk,
      ),
      (SubagentEscalation.deny, Lucide.Ban, l10n.subagentEscalationDeny),
      (
        SubagentEscalation.allow,
        Lucide.CircleAlert,
        l10n.subagentEscalationAllow,
      ),
    ];
    final picked = await (PlatformUtils.isDesktop
        ? showDialog<SubagentEscalation>(
            context: context,
            builder: (dialogContext) => Dialog(
              clipBehavior: Clip.antiAlias,
              child: _EscalationChoices(
                rows: rows,
                current: current,
                onPick: (value) => Navigator.of(dialogContext).pop(value),
              ),
            ),
          )
        : showModalBottomSheet<SubagentEscalation>(
            context: context,
            showDragHandle: true,
            builder: (sheetContext) => SafeArea(
              child: _EscalationChoices(
                rows: rows,
                current: current,
                onPick: (value) => Navigator.of(sheetContext).pop(value),
              ),
            ),
          ));
    if (picked == null || picked == current) return;
    final latest = assistants.getById(assistant.id) ?? assistant;
    await assistants.updateAssistant(
      latest.copyWith(subagentEscalation: picked),
    );
  }

  /// Delegation and its blocking counter are one capability, so one switch writes
  /// both ids: a model that can delegate but cannot wait would have to rediscover
  /// that its answer arrives later on every turn.
  static Future<void> _setEnabled(
    BuildContext context,
    Assistant assistant,
    bool value,
  ) async {
    final assistants = context.read<AssistantProvider>();
    final latest = assistants.getById(assistant.id) ?? assistant;
    final ids = latest.localToolIds.toList()
      ..remove(LocalToolNames.delegate)
      ..remove(LocalToolNames.awaitJob);
    if (value) {
      ids
        ..add(LocalToolNames.delegate)
        ..add(LocalToolNames.awaitJob);
    }
    Haptics.light();
    await assistants.updateAssistant(latest.copyWith(localToolIds: ids));
  }

  static Future<void> _pickModel(
    BuildContext context,
    Assistant assistant,
  ) async {
    final assistants = context.read<AssistantProvider>();
    final current = resolveSubagentModel(assistant);
    final pickerHost = context;
    final selection = await showModelSelector(
      pickerHost,
      initialProviderKey: current?.providerId,
      initialModelId: current?.modelId,
      allowInherit: true,
      inheritLabel: AppLocalizations.of(pickerHost)!.subagentConfigModelInherit,
    );
    if (selection == null) return;
    final latest = assistants.getById(assistant.id) ?? assistant;
    await assistants.updateAssistant(
      selection.isInherit
          ? latest.copyWith(
              clearSubagentModelProvider: true,
              clearSubagentModelId: true,
            )
          : latest.copyWith(
              subagentModelProvider: selection.providerKey,
              subagentModelId: selection.modelId,
            ),
    );
  }
}

/// One line of the dialog: name, an optional sentence about the option, and the
/// current value on the right. The description describes the *option*; the value
/// is the state, and they never share a line.
class _ConfigRow extends StatelessWidget {
  const _ConfigRow({
    required this.label,
    this.description,
    this.value,
    this.trailing,
    this.onTap,
  });

  final String label;
  final String? description;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 15)),
                if (description case final text?) ...[
                  const SizedBox(height: 2),
                  Text(
                    text,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: cs.onSurface.withValues(alpha: .55),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (value case final text?) ...[
            const SizedBox(width: 12),
            Text(
              text,
              style: TextStyle(
                fontSize: 13.5,
                color: cs.onSurface.withValues(alpha: .6),
              ),
            ),
          ],
          if (trailing case final widget?)
            widget
          else if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(
              Lucide.ChevronRight,
              size: 16,
              color: cs.onSurface.withValues(alpha: .35),
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: row,
    );
  }
}

/// The three escalation choices, shared by the dialog and the sheet so the two
/// surfaces cannot drift apart.
class _EscalationChoices extends StatelessWidget {
  const _EscalationChoices({
    required this.rows,
    required this.current,
    required this.onPick,
  });

  final List<(SubagentEscalation, IconData, String)> rows;
  final SubagentEscalation current;
  final ValueChanged<SubagentEscalation> onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (value, icon, label) in rows)
            InkWell(
              onTap: () => onPick(value),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 18,
                      color: switch (value) {
                        SubagentEscalation.ask => cs.onSurface.withValues(
                          alpha: .6,
                        ),
                        SubagentEscalation.deny => cs.error,
                        SubagentEscalation.allow => const Color(0xFFE0A34A),
                      },
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 15,
                          color: value == current ? cs.primary : cs.onSurface,
                        ),
                      ),
                    ),
                    if (value == current)
                      Icon(Lucide.Check, size: 16, color: cs.primary),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
