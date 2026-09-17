import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/proactive_care_conversation_policy.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_settings_rows.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../theme/app_font_weights.dart';

/// Assistant edit tab: proactive care ("Ta 的来信") settings.
///
/// Covers the engine surface ported to the working tree: the enable switch,
/// the care/decision prompts, the decision history limit and per-conversation
/// time overrides. (The fork's Android alarm-permission section is not part
/// of this port: delivery runs in-app, notifications only nudge.)
class AssistantProactiveLetterTab extends StatefulWidget {
  const AssistantProactiveLetterTab({super.key, required this.assistantId});

  final String assistantId;

  @override
  State<AssistantProactiveLetterTab> createState() =>
      _AssistantProactiveLetterTabState();
}

class _AssistantProactiveLetterTabState
    extends State<AssistantProactiveLetterTab> {
  bool _conversationTimesExpanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final assistantProvider = context.watch<AssistantProvider>();
    final assistant = assistantProvider.getById(widget.assistantId);
    if (assistant == null) {
      return Center(
        child: Text(l10n.assistantEditProactiveCareNoEligibleConversations),
      );
    }
    final chatService = context.read<ChatService>();
    final conversations = chatService
        .getAllConversations()
        .where((c) => c.assistantId == assistant.id)
        .toList(growable: false);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        SectionCard(
          child: Column(
            children: [
              IosSwitchRow(
                icon: Lucide.HeartPulse,
                label: l10n.assistantEditProactiveCareEnableTitle,
                value: assistant.enableProactiveCare,
                onChanged: (v) =>
                    _update(assistant.copyWith(enableProactiveCare: v)),
                subtitle: l10n.assistantEditProactiveCareDefaultDescription,
              ),
              const IosRowDivider(),
              IosNavRow(
                icon: Lucide.MessageSquare,
                label: l10n.assistantEditProactiveCareDecisionHistoryLimitTitle,
                detailText:
                    assistant.proactiveCareDecisionHistoryMessageLimit
                        ?.toString() ??
                    l10n.assistantEditParameterDisabled2,
                onTap: () => _showLimitSheet(context, assistant),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _PromptSection(
          icon: Lucide.Mail,
          title: l10n.assistantEditProactiveCarePromptTitle,
          hint: l10n.assistantEditProactiveCarePromptHint,
          value: assistant.proactiveCarePrompt,
          maxLines: 5,
          onChanged: (v) => _update(assistant.copyWith(proactiveCarePrompt: v)),
        ),
        const SizedBox(height: 12),
        _PromptSection(
          icon: Lucide.clock,
          title: l10n.assistantEditProactiveCareDecisionPromptTitle,
          hint: l10n.assistantEditProactiveCarePromptHint,
          value: assistant.proactiveCareDecisionPrompt,
          maxLines: 5,
          onChanged: (v) =>
              _update(assistant.copyWith(proactiveCareDecisionPrompt: v)),
        ),
        const SizedBox(height: 12),
        SectionCard(
          child: Column(
            children: [
              IosNavRow(
                icon: Lucide.MessageSquare,
                label: l10n.assistantEditProactiveCareConversationTimesTitle,
                detailText: conversations.isEmpty
                    ? l10n.assistantEditProactiveCareNoEligibleConversations
                    : null,
                trailing: Icon(
                  _conversationTimesExpanded
                      ? Lucide.ChevronUp
                      : Lucide.ChevronDown,
                  size: 18,
                  color: cs.onSurface.withValues(alpha: 0.5),
                ),
                onTap: () => setState(
                  () =>
                      _conversationTimesExpanded = !_conversationTimesExpanded,
                ),
              ),
              if (_conversationTimesExpanded) ...[
                const IosRowDivider(),
                for (final conversation in conversations) ...[
                  _ConversationTimeRow(
                    conversation: conversation,
                    eligible:
                        ProactiveCareConversationPolicy.isEffectivelyEnabled(
                          conversation,
                          assistant,
                        ),
                    onChanged: () => setState(() {}),
                  ),
                  const IosRowDivider(),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _update(Assistant next) async {
    await context.read<AssistantProvider>().updateAssistant(next);
    if (mounted) setState(() {});
  }

  Future<void> _showLimitSheet(BuildContext context, Assistant assistant) {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(
      text:
          (assistant.proactiveCareDecisionHistoryMessageLimit ??
                  Assistant.defaultRecentChatsSummaryMessageCount)
              .toString(),
    );
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Text(
                    l10n.assistantEditProactiveCareDecisionHistoryLimitTitle,
                    style: Theme.of(sheetContext).textTheme.bodyLarge!.copyWith(
                      fontWeight: AppFontWeights.emphasis,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    l10n.assistantEditProactiveCareDecisionHistoryLimitDescription,
                    style: Theme.of(sheetContext).textTheme.bodySmall,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                  child: TextField(
                    controller: controller,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                OverflowBar(
                  alignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: () async {
                        await _update(
                          assistant.copyWith(
                            clearProactiveCareDecisionHistoryMessageLimit: true,
                          ),
                        );
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                      },
                      child: Text(l10n.assistantEditParameterDisabled2),
                    ),
                    FilledButton(
                      onPressed: () async {
                        final parsed = int.tryParse(controller.text.trim());
                        if (parsed == null) return;
                        await _update(
                          assistant.copyWith(
                            proactiveCareDecisionHistoryMessageLimit: parsed,
                          ),
                        );
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                      },
                      child: Text(l10n.assistantEditEmojiDialogSave),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PromptSection extends StatelessWidget {
  const _PromptSection({
    required this.icon,
    required this.title,
    required this.hint,
    required this.value,
    required this.onChanged,
    this.maxLines = 4,
  });

  final IconData icon;
  final String title;
  final String hint;
  final String value;
  final ValueChanged<String> onChanged;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                    fontWeight: AppFontWeights.emphasis,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: TextEditingController(text: value)
              ..selection = TextSelection.collapsed(offset: value.length),
            maxLines: maxLines,
            onChanged: onChanged,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              hint: Text(hint),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConversationTimeRow extends StatelessWidget {
  const _ConversationTimeRow({
    required this.conversation,
    required this.eligible,
    required this.onChanged,
  });

  final Conversation conversation;
  final bool eligible;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final chatService = context.read<ChatService>();
    final nextAt = conversation.proactiveCareNextMessageAt;
    final formatted = nextAt?.toLocal().toString().substring(0, 16) ?? '';
    return IosNavRow(
      label: conversation.title,
      caption: eligible
          ? (nextAt == null
                ? l10n.assistantEditProactiveCareConversationTimeUnset
                : nextAt.isAfter(DateTime.now())
                ? l10n.assistantEditProactiveCareConversationTimeFuture(
                    formatted,
                  )
                : l10n.assistantEditProactiveCareConversationTimeExpired(
                    formatted,
                  ))
          : l10n.assistantEditProactiveCareDefaultDescription,
      trailing: Switch(
        value: eligible,
        onChanged: (v) async {
          await chatService.updateConversationExtras(conversation.id, (extras) {
            extras[Conversation.proactiveCareEnabledOverrideKey] = v;
            return extras;
          });
          onChanged();
        },
      ),
    );
  }
}
