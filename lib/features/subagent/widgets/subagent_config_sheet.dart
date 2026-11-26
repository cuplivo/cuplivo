/// The 子代理 configuration: one row in the toolbox, and what it runs with.
///
/// The toolbox row is the switch, exactly as 绘图's is — a check on a desktop, a
/// toggle on a phone. What can be decided lives in the summary line under it
/// (深度, 目标, 模型, 提权), which opens this dialog; the dialog repeats no
/// switch, because the row that opened it already is one.
///
/// A phone gets a sheet and a desktop gets a dialog: the repo never puts a bottom
/// sheet on a desktop window, whatever its width.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../utils/platform_utils.dart';
import '../../group_chat/widgets/group_member_list.dart'
    show showGroupMemberPickerDialog;
import '../../home/utils/model_display_helper.dart';
import '../../home/widgets/assistant_avatar.dart';
import '../../model/widgets/model_select_sheet.dart';
import '../services/subagent_model.dart';
import '../services/subagent_rules.dart' show delegableAssistants, parentDepth;

/// The toolbox row's second line: what a delegation would run on, who it may
/// name, and how deep it may go.
///
/// The target count appears only when there is one: an assistant that names
/// nobody keeps the two-part summary it had before targets existed.
String subagentSummary(
  BuildContext context,
  AppLocalizations l10n,
  Assistant assistant,
) {
  final model = _modelLabel(context, l10n, resolveSubagentModel(assistant));
  final targets = _countTargets(context, assistant);
  final depth = assistant.subagentDepth;
  if (targets == 0) {
    return l10n.subagentConfigSummary(model, depth);
  }
  return l10n.subagentConfigSummaryWithTargets(model, targets, depth);
}

/// What the delegation's model is called, wherever it is shown: the name its
/// provider gives it, or 继承 when the delegation has no model of its own.
String _modelLabel(
  BuildContext context,
  AppLocalizations l10n,
  SubagentModelBinding? binding,
) {
  if (binding == null) return l10n.subagentConfigModelInherit;
  return modelDisplayName(
    context.read<SettingsProvider>(),
    binding.providerId,
    binding.modelId,
  );
}

/// How many assistants a delegation from [assistant] may name, by the same rule
/// the tool schema uses.
int _countTargets(BuildContext context, Assistant assistant) {
  try {
    return delegableAssistants(
      delegator: assistant,
      all: context.read<AssistantProvider>().assistants,
    ).length;
  } catch (_) {
    return 0;
  }
}

/// Opens the configuration for delegating with [assistantId] from
/// [conversationId].
///
/// The conversation is passed in rather than read from the chat's "current" one:
/// a desktop popover can be opened for a member the user is not writing as, and
/// the depth of *this* conversation is what decides whether a second-level
/// delegation may still choose its own escalation.
///
/// A desktop gets a dialog and a phone gets a sheet. The test is the platform,
/// not the window width: the repo never puts a bottom sheet on desktop, and a
/// narrow desktop window is still a desktop.
Future<void> showSubagentConfig(
  BuildContext context, {
  required String assistantId,
  String? conversationId,
}) {
  final body = _SubagentConfigBody(
    assistantId: assistantId,
    conversationId: conversationId,
  );
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
  const _SubagentConfigBody({
    required this.assistantId,
    required this.conversationId,
  });

  final String assistantId;
  final String? conversationId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final assistant = context.select<AssistantProvider, Assistant?>(
      (provider) => provider.getById(assistantId),
    );
    if (assistant == null) return const SizedBox.shrink();
    final model = resolveSubagentModel(assistant);
    final targets = _otherAssistants(context, assistant);
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
          // How deep a delegation may nest below this assistant. The row was
          // read-only while nesting past one level was open; it is a picker now
          // that the chain carries its own budget.
          _ConfigRow(
            label: l10n.subagentConfigDepth,
            description: l10n.subagentConfigDepthDescription,
            value: '${assistant.subagentDepth}',
            onTap: () => _pickDepth(context, assistant),
          ),
          // Which assistants a delegation may name. Absent until there is
          // somebody to name: an assistant alone in the app has nothing to
          // choose between, and the row would only explain a feature it cannot
          // demonstrate.
          if (targets.isNotEmpty)
            _ConfigRow(
              label: l10n.subagentConfigTargets,
              description: l10n.subagentConfigTargetsDescription,
              value: _targetsLabel(l10n, assistant, targets),
              onTap: () => _pickTargets(context, assistant, targets),
            ),
          _ConfigRow(
            label: l10n.subagentConfigModel,
            description: l10n.subagentConfigModelDescription,
            value: _modelLabel(context, l10n, model),
            onTap: () => _pickModel(context, assistant),
          ),
          // A delegation made from a subagent conversation is a second-level
          // one, and it never chooses its own escalation: the chain's policy was
          // settled by the conversation that started it, and only ever narrows.
          if (_conversationDepthOf(context) == 0)
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

  /// Every assistant this one could name — everybody else in the app.
  ///
  /// The selection is a filter on top of this list, so the picker always shows
  /// the full menu with the selected ones ticked: a user who wants to change
  /// their mind needs to see what they did not choose.
  static List<Assistant> _otherAssistants(
    BuildContext context,
    Assistant assistant,
  ) {
    final all = context.read<AssistantProvider>().assistants;
    return <Assistant>[
      for (final other in all)
        if (other.id != assistant.id) other,
    ];
  }

  /// What the row says.
  ///
  /// A count, never a single assistant's name: with one target selected the
  /// name filled the value slot and was already clipped, so the row would have
  /// read as the only assistant that exists.
  static String _targetsLabel(
    AppLocalizations l10n,
    Assistant assistant,
    List<Assistant> candidates,
  ) {
    final selected = delegableAssistants(delegator: assistant, all: candidates);
    if (selected.isEmpty) return l10n.subagentConfigTargetsSelf;
    return l10n.subagentConfigTargetsSelfPlus(selected.length);
  }

  /// The fixed part of the picker: a copy of this assistant is always available,
  /// and the ticked list below is what may be named on top of it.
  ///
  /// The row is deliberately not a checkbox: "delegate to yourself" is not an
  /// option this setting owns, it is what the feature is, and a control that
  /// cannot be turned off is a worse lie than a line that never pretended to be
  /// one.
  static Widget _targetsHeader(
    BuildContext context,
    Assistant self,
    AppLocalizations l10n,
  ) {
    final cs = Theme.of(context).colorScheme;
    // 10 px matches the picker's own rows, so the fixed row and the candidates
    // share one left edge.
    Widget section(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: cs.onSurface.withValues(alpha: .55),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        section(l10n.subagentConfigTargetsSelfSection),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              AssistantAvatar(assistant: self, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.subagentConfigTargetsSelf,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14.5),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.subagentConfigTargetsSelfCaption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: cs.onSurface.withValues(alpha: .55),
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                l10n.subagentConfigTargetsAlways,
                style: TextStyle(
                  fontSize: 11.5,
                  color: cs.onSurface.withValues(alpha: .45),
                ),
              ),
              const SizedBox(width: 6),
              Icon(Lucide.CheckCircle, size: 20, color: cs.primary),
            ],
          ),
        ),
        Divider(
          height: 1,
          thickness: .5,
          color: cs.outlineVariant.withValues(alpha: .2),
        ),
        section(l10n.subagentConfigTargetsOthersSection),
      ],
    );
  }

  static Widget _targetsFooter(BuildContext context, AppLocalizations l10n) =>
      Text(
        l10n.subagentConfigTargetsFooter,
        maxLines: 2,
        style: TextStyle(
          fontSize: 12,
          height: 1.35,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .55),
        ),
      );

  /// Picks the targets. The picker is the group chat's member picker with a
  /// fixed row above the list and one sentence at the bottom.
  ///
  /// An empty selection is a real answer here ("only yourself"), not a cancel —
  /// the group's invite path treats it as one because inviting nobody is not a
  /// request, whereas naming nobody is exactly what this row is for.
  static Future<void> _pickTargets(
    BuildContext context,
    Assistant assistant,
    List<Assistant> candidates,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final assistants = context.read<AssistantProvider>();
    final picked = await showGroupMemberPickerDialog(
      context,
      title: l10n.subagentConfigTargets,
      candidates: candidates,
      initialSelection: assistant.subagentTargetIds,
      header: _targetsHeader(context, assistant, l10n),
      footer: _targetsFooter(context, l10n),
    );
    if (picked == null) return;
    final latest = assistants.getById(assistant.id) ?? assistant;
    await assistants.updateAssistant(
      latest.copyWith(subagentTargetIds: picked),
    );
  }

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

  /// Picks how deep delegations from this assistant may nest.
  ///
  /// The same two shells as the escalation picker: a dialog on a desktop, a
  /// sheet on a phone. Each choice carries the sentence that says what it means,
  /// because "1" alone does not tell a user whether the subagent disappears.
  static Future<void> _pickDepth(
    BuildContext context,
    Assistant assistant,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final assistants = context.read<AssistantProvider>();
    final current = assistant.subagentDepth;
    final rows = <(int, String)>[
      (1, l10n.subagentConfigDepthOne),
      (2, l10n.subagentConfigDepthTwo),
      (3, l10n.subagentConfigDepthThree),
    ];
    final picked = await (PlatformUtils.isDesktop
        ? showDialog<int>(
            context: context,
            builder: (dialogContext) => Dialog(
              clipBehavior: Clip.antiAlias,
              child: _DepthChoices(
                rows: rows,
                current: current,
                onPick: (value) => Navigator.of(dialogContext).pop(value),
              ),
            ),
          )
        : showModalBottomSheet<int>(
            context: context,
            showDragHandle: true,
            builder: (sheetContext) => SafeArea(
              child: _DepthChoices(
                rows: rows,
                current: current,
                onPick: (value) => Navigator.of(sheetContext).pop(value),
              ),
            ),
          ));
    if (picked == null || picked == current) return;
    final latest = assistants.getById(assistant.id) ?? assistant;
    await assistants.updateAssistant(latest.copyWith(subagentDepth: picked));
  }

  /// How deep [conversationId] already sits. Zero for an ordinary conversation,
  /// for a conversation that is gone, and for a caller that named none.
  int _conversationDepthOf(BuildContext context) {
    final id = conversationId;
    if (id == null) return 0;
    try {
      final extras = context.read<ChatService>().getConversation(id)?.extras;
      return extras == null ? 0 : parentDepth(extras);
    } catch (_) {
      return 0;
    }
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
    this.onTap,
  });

  final String label;
  final String? description;
  final String? value;
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
          if (onTap != null) ...[
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

/// The three depth choices, shared by the dialog and the sheet so the two
/// surfaces cannot drift apart.
class _DepthChoices extends StatelessWidget {
  const _DepthChoices({
    required this.rows,
    required this.current,
    required this.onPick,
  });

  final List<(int, String)> rows;
  final int current;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (value, label) in rows)
            InkWell(
              onTap: () => onPick(value),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      child: Text(
                        '$value',
                        style: TextStyle(
                          fontSize: 15,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: value == current
                              ? cs.primary
                              : cs.onSurface.withValues(alpha: .8),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.35,
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
