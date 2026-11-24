import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/message_part.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/markdown/markdown_with_code_highlight.dart';
import '../../../shared/responsive/screen_type_helper.dart';
import '../../../shared/widgets/snackbar.dart';
import '../services/subagent_coordinator.dart';

/// The one line a mail row shows, in the timeline and in every export.
///
/// The label names the sender's side, so it reads the same in both
/// conversations: a row in the parent comes from the subagent, a row in the
/// child comes from the delegator. Shared so a screenshot, a Markdown export and
/// a PDF cannot drift from the timeline.
String subagentMailLabelText(
  AppLocalizations l10n,
  SubagentMailPart part,
  String senderTitle,
) {
  final title = senderTitle.trim();
  final label = part.from == SubagentMailSender.delegator
      ? l10n.subagentMailDelegatorLabel
      : l10n.subagentMailLabel;
  return title.isEmpty ? label : '$label · $title';
}

/// One message between the two sides of a delegation, drawn as what it is.
///
/// The row is a `user` message because that is the role the receiving model has
/// to read, but no person in this conversation wrote it. It uses the same 28px
/// divider as a delegation's result instead of a bubble: one visual system for
/// "this came from the other side", and the timeline stays the parent's own
/// conversation — the child's words are not printed into it line by line.
///
/// The message itself is one tap away: the divider opens the whole message in a
/// dialog (desktop) or a sheet (mobile), rendered with the same Markdown widget
/// the timeline uses, with a copy action and a way into the conversation that
/// sent it. The body is not a preview; nothing is hidden behind a second tap.
///
/// The body is the row's own text. The prefix the model reads
/// ("The delegator sent a message: …") is added when the request is assembled,
/// not stored here — see `message_builder_service.dart`.
class SubagentMailNotice extends StatelessWidget {
  const SubagentMailNotice({
    super.key,
    required this.part,
    required this.message,
  });

  final SubagentMailPart part;
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final title = _senderTitle(context);
    final label = subagentMailLabelText(l10n, part, title);
    final hasBody = message.content.trim().isNotEmpty;

    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: hasBody ? () => _open(context) : null,
      child: SizedBox(
        height: 28,
        child: Row(
          children: [
            Expanded(
              child: Divider(
                height: 1,
                thickness: 1,
                color: cs.outlineVariant.withValues(alpha: .6),
              ),
            ),
            Flexible(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 320),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      part.from == SubagentMailSender.subagent
                          ? Lucide.Bot
                          : Lucide.MessageCircle,
                      size: 14,
                      color: cs.onSurface.withValues(alpha: .55),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: cs.onSurface.withValues(alpha: .6),
                        ),
                      ),
                    ),
                    if (hasBody) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Lucide.ChevronRight,
                        size: 13,
                        color: cs.onSurface.withValues(alpha: .45),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Expanded(
              child: Divider(
                height: 1,
                thickness: 1,
                color: cs.outlineVariant.withValues(alpha: .6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _senderTitle(BuildContext context) =>
      (context
                  .read<ChatService?>()
                  ?.getConversation(part.senderConversationId)
                  ?.title ??
              '')
          .trim();

  void _open(BuildContext context) {
    final title = _senderTitle(context);
    final l10n = AppLocalizations.of(context)!;
    final content = _MailDialog(
      part: part,
      label: subagentMailLabelText(l10n, part, title),
      body: message.content.trim(),
      conversationId: message.conversationId,
    );
    if (ResponsiveHelper.isDesktop(context)) {
      showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: content,
          ),
        ),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => content,
    );
  }
}

/// The whole message, rendered the way the timeline renders prose.
class _MailDialog extends StatelessWidget {
  const _MailDialog({
    required this.part,
    required this.label,
    required this.body,
    required this.conversationId,
  });

  final SubagentMailPart part;
  final String label;
  final String body;
  final String conversationId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  part.from == SubagentMailSender.subagent
                      ? Lucide.Bot
                      : Lucide.MessageCircle,
                  size: 16,
                  color: cs.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: MarkdownWithCodeHighlight(
                  text: body,
                  baseStyle: const TextStyle(fontSize: 14.5, height: 1.7),
                  conversationId: conversationId,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () async {
                    await copyTextWithConfirmation(
                      context,
                      body,
                      message: l10n.subagentMailCopied,
                    );
                  },
                  icon: const Icon(Lucide.Copy, size: 15),
                  label: Text(l10n.subagentMailCopy),
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: () {
                    final coordinator = subagentCoordinatorOf(context);
                    Navigator.of(context).pop();
                    coordinator?.openChild(part.senderConversationId);
                  },
                  icon: const Icon(Lucide.ExternalLink, size: 15),
                  label: Text(l10n.subagentMailOpenConversation),
                ),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    MaterialLocalizations.of(context).closeButtonLabel,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
