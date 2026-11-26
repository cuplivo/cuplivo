import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/message_part.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../icons/lucide_adapter.dart';

/// One message between the two sides of a delegation, drawn as what it is.
///
/// The row is a `user` message because that is the role the receiving model has
/// to read, but no person in this conversation wrote it: drawing it with the
/// user's own bubble attributes the sentence to the human, and the model-facing
/// attribution sentence is English in every locale. The sender's conversation
/// title is data, so this card can say who is talking without a localized verb.
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
    final cs = Theme.of(context).colorScheme;
    final sender = context.read<ChatService?>()?.getConversation(
      part.senderConversationId,
    );
    final title = (sender?.title ?? '').trim();
    final body = message.content.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: .55),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: .6)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    part.from == SubagentMailSender.subagent
                        ? Lucide.Bot
                        : Lucide.MessageCircle,
                    size: 14,
                    color: cs.onSurfaceVariant,
                  ),
                  if (title.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (body.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(body, style: TextStyle(fontSize: 14, color: cs.onSurface)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
