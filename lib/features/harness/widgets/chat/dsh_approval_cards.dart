import 'package:flutter/material.dart';

import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/shared/widgets/section_card.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

/// The blocking host requests of one session, rendered as cards above the
/// composer.
///
/// A DSH approval or user question is a `$events` waterfall the turn is waiting
/// on: the UI must show it and must not default it. Both cards therefore expose
/// an explicit affirmative and an explicit refusal.
class DshPendingRequestPanel extends StatelessWidget {
  const DshPendingRequestPanel({
    super.key,
    this.approvals = const <DshPendingApproval>[],
    this.questions = const <DshPendingQuestion>[],
    required this.onAnswerApproval,
    required this.onAnswerQuestions,
    required this.onRejectQuestions,
  });

  final List<DshPendingApproval> approvals;
  final List<DshPendingQuestion> questions;
  final void Function(DshPendingApproval approval, bool allow) onAnswerApproval;
  final void Function(
    DshPendingQuestion request,
    List<DshQuestionAnswer> answers,
  )
  onAnswerQuestions;
  final void Function(DshPendingQuestion request) onRejectQuestions;

  bool get isEmpty => approvals.isEmpty && questions.isEmpty;

  @override
  Widget build(BuildContext context) {
    if (isEmpty) return const SizedBox.shrink();
    return Column(
      key: const ValueKey<String>('dsh-pending-requests'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final approval in approvals)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: DshApprovalCard(
              key: ValueKey<String>('dsh-approval-${approval.id}'),
              approval: approval,
              onAllow: () => onAnswerApproval(approval, true),
              onDeny: () => onAnswerApproval(approval, false),
            ),
          ),
        for (final request in questions)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: DshQuestionCard(
              key: ValueKey<String>('dsh-question-${request.id}'),
              request: request,
              onSubmit: (answers) => onAnswerQuestions(request, answers),
              onReject: () => onRejectQuestions(request),
            ),
          ),
      ],
    );
  }
}

/// One approval request: which tool wants to run, why, and allow/deny.
class DshApprovalCard extends StatelessWidget {
  const DshApprovalCard({
    super.key,
    required this.approval,
    required this.onAllow,
    required this.onDeny,
  });

  final DshPendingApproval approval;
  final VoidCallback onAllow;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final reason = (approval.reason ?? '').trim();
    return SectionCard(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      crossAxisAlignment: CrossAxisAlignment.start,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Lucide.ShieldAlert,
                size: 17,
                color: context.appColors.warning,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  l10n.dshApprovalTitle,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: AppFontWeights.semibold,
                    color: cs.onSurface,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  approval.toolName,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: cs.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ],
          ),
          if (reason.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              reason,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _DshCardAction(
                key: const ValueKey<String>('dsh-approval-deny'),
                label: l10n.dshApprovalDeny,
                onTap: onDeny,
              ),
              const SizedBox(width: 8),
              _DshCardAction(
                key: const ValueKey<String>('dsh-approval-allow'),
                label: l10n.dshApprovalAllow,
                accent: true,
                onTap: onAllow,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One user-questions request. Options become tappable pills; a question with
/// no options accepts a short free-form answer. Submit stays disabled until
/// every question is answered, so nothing is ever defaulted.
class DshQuestionCard extends StatefulWidget {
  const DshQuestionCard({
    super.key,
    required this.request,
    required this.onSubmit,
    required this.onReject,
  });

  final DshPendingQuestion request;
  final ValueChanged<List<DshQuestionAnswer>> onSubmit;
  final VoidCallback onReject;

  @override
  State<DshQuestionCard> createState() => _DshQuestionCardState();
}

class _DshQuestionCardState extends State<DshQuestionCard> {
  final Map<String, Set<String>> _selected = <String, Set<String>>{};
  final Map<String, TextEditingController> _custom =
      <String, TextEditingController>{};

  @override
  void dispose() {
    for (final controller in _custom.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(String questionId) =>
      _custom.putIfAbsent(questionId, TextEditingController.new);

  bool _questionAnswered(DshUserQuestion question) {
    final selected = _selected[question.id];
    if (selected != null && selected.isNotEmpty) return true;
    if (!question.hasOptions) {
      return _controllerFor(question.id).text.trim().isNotEmpty;
    }
    return false;
  }

  bool get _canSubmit => widget.request.questions.every(_questionAnswered);

  void _toggleOption(DshUserQuestion question, String label) {
    setState(() {
      final selected = _selected.putIfAbsent(question.id, () => <String>{});
      if (question.multiSelect) {
        if (!selected.remove(label)) selected.add(label);
      } else {
        selected
          ..clear()
          ..add(label);
      }
    });
  }

  void _submit() {
    if (!_canSubmit) return;
    final answers = <DshQuestionAnswer>[
      for (final question in widget.request.questions)
        DshQuestionAnswer(
          questionId: question.id,
          selected: (_selected[question.id] ?? const <String>{}).toList(),
          custom: question.hasOptions
              ? null
              : _controllerFor(question.id).text.trim(),
        ),
    ];
    widget.onSubmit(answers);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return SectionCard(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      crossAxisAlignment: CrossAxisAlignment.start,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Lucide.MessageCircle, size: 17, color: cs.primary),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  l10n.dshQuestionTitle,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: AppFontWeights.semibold,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
          for (final question in widget.request.questions) ...[
            const SizedBox(height: 8),
            if ((question.header ?? '').trim().isNotEmpty)
              Text(
                question.header!.trim(),
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: AppFontWeights.semibold,
                  color: cs.onSurface.withValues(alpha: 0.5),
                ),
              ),
            Text(
              question.question,
              style: TextStyle(fontSize: 13, height: 1.35, color: cs.onSurface),
            ),
            if ((question.detail ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                question.detail!.trim(),
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
            const SizedBox(height: 8),
            if (question.hasOptions)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in question.options)
                    _DshOptionPill(
                      key: ValueKey<String>(
                        'dsh-question-option-${question.id}-${option.label}',
                      ),
                      option: option,
                      selected: (_selected[question.id] ?? const <String>{})
                          .contains(option.label),
                      onTap: () => _toggleOption(question, option.label),
                    ),
                ],
              )
            else
              TextField(
                key: ValueKey<String>('dsh-question-input-${question.id}'),
                controller: _controllerFor(question.id),
                onChanged: (_) => setState(() {}),
                minLines: 1,
                maxLines: 3,
                style: TextStyle(fontSize: 13, color: cs.onSurface),
                decoration: InputDecoration(
                  hintText: l10n.dshQuestionFreeformHint,
                  isDense: true,
                  filled: true,
                  fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
          ],
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _DshCardAction(
                key: const ValueKey<String>('dsh-question-reject'),
                label: l10n.dshQuestionReject,
                onTap: widget.onReject,
              ),
              const SizedBox(width: 8),
              _DshCardAction(
                key: const ValueKey<String>('dsh-question-submit'),
                label: l10n.dshQuestionSubmit,
                accent: true,
                enabled: _canSubmit,
                onTap: _submit,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DshOptionPill extends StatelessWidget {
  const _DshOptionPill({
    super.key,
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final DshQuestionOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: IosCardPress(
        baseColor: selected
            ? cs.primary.withValues(alpha: 0.12)
            : sheetTileColor(context),
        borderRadius: BorderRadius.circular(10),
        pressedBlendStrength: 0.10,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              Icon(Lucide.Check, size: 13, color: cs.primary),
              const SizedBox(width: 4),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    option.label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: AppFontWeights.medium,
                      color: selected ? cs.primary : cs.onSurface,
                    ),
                  ),
                  if ((option.description ?? '').trim().isNotEmpty)
                    Text(
                      option.description!.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DshCardAction extends StatelessWidget {
  const _DshCardAction({
    super.key,
    required this.label,
    required this.onTap,
    this.accent = false,
    this.enabled = true,
  });

  final String label;
  final VoidCallback onTap;
  final bool accent;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = accent ? cs.primary : cs.onSurface.withValues(alpha: 0.7);
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: IosCardPress(
        baseColor: accent
            ? cs.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        pressedBlendStrength: 0.08,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        onTap: enabled ? onTap : null,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: AppFontWeights.medium,
            color: color,
          ),
        ),
      ),
    );
  }
}
