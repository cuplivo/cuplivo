import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/message_quote.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../utils/reply_citation_label.dart';

/// The one-line reply citation that sits above a message's content,
/// QQ-style (docs/adr/0011).
///
/// A ranged citation carries its own markdown, so it shows that text whatever
/// happened to its target — the target only feeds the tap that jumps to it. A
/// whole-message citation has no text of its own: it shows [target]'s rendered
/// text, or the localized stub once the target cannot be resolved (deleted, or
/// outside the loaded window).
class QuoteCitation extends StatelessWidget {
  const QuoteCitation({
    super.key,
    required this.quote,
    this.target,
    this.onTap,
  });

  final MessageQuote quote;

  /// The quoted message, when it is in the loaded window.
  final ChatMessage? target;

  /// Jumps to the quoted message. Null when it cannot be resolved.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final settings = context.read<SettingsProvider>();
    final own = quote.text;
    final resolved = target;
    final String label;
    if (own != null) {
      label = replyCitationLabel(own, settings: settings);
    } else if (resolved != null) {
      label = replyCitationLabel(
        resolved.content,
        settings: settings,
        streaming: resolved.isStreaming,
      );
    } else {
      label = l10n.messageQuoteTargetMissing;
    }

    final muted = cs.onSurface.withValues(alpha: 0.55);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        // The citation belongs to the right-aligned user turn it sits above, so
        // it leans right whatever box a caller hands it (docs/adr/0011).
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Icon(Lucide.Reply, size: 13, color: muted),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: TextStyle(fontSize: 11.5, height: 1.25, color: muted),
            ),
          ),
        ],
      ),
    );
  }
}
