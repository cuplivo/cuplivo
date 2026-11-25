import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/message_part.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/responsive/screen_type_helper.dart';

/// One message between the two sides of a delegation, drawn as what it is.
///
/// The row is a `user` message because that is the role the receiving model has
/// to read, but no person in this conversation wrote it. It uses the same 28px
/// divider as a delegation's result instead of a bubble: one visual system for
/// "this came from the other side", so the timeline, the PNG share and a PDF all
/// draw it the same way.
///
/// Unlike a result, the message itself is the point — the parent acts on it —
/// so the body stays under the line. Tapping the line opens the whole message in
/// a dialog (desktop) or a sheet (mobile); the body is not a preview that hides
/// anything.
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
    final label = title.isEmpty
        ? l10n.subagentMailLabel
        : '${l10n.subagentMailLabel} · $title';
    final body = message.content.trim();

    final line = SizedBox(
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
                  const SizedBox(width: 4),
                  Icon(
                    Lucide.ChevronRight,
                    size: 13,
                    color: cs.onSurface.withValues(alpha: .45),
                  ),
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
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: body.isEmpty ? null : () => _open(context),
          child: line,
        ),
        if (body.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            body,
            style: TextStyle(fontSize: 14, height: 1.7, color: cs.onSurface),
          ),
        ],
      ],
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
    final content = _MailSheet(
      part: part,
      title: _senderTitle(context),
      body: message.content.trim(),
    );
    if (ResponsiveHelper.isDesktop(context)) {
      showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
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

/// The whole message, without the timeline's width.
class _MailSheet extends StatelessWidget {
  const _MailSheet({
    required this.part,
    required this.title,
    required this.body,
  });

  final SubagentMailPart part;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
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
                    title.isEmpty
                        ? l10n.subagentMailLabel
                        : '${l10n.subagentMailLabel} · $title',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  body,
                  style: TextStyle(
                    fontSize: 14.5,
                    height: 1.7,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(MaterialLocalizations.of(context).closeButtonLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
