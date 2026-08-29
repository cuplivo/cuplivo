import 'package:flutter/material.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/message_quote.dart';
import '../../../l10n/app_localizations.dart';
import '../../../utils/quote_plain_text.dart';

/// QQ-style one-line reply citation (issue #312, docs/adr/0046).
///
/// [target] is the resolved quoted message row; null renders the localized
/// stub (deleted / restore-mismatched target). Display extracts via the
/// shared [quotePlainText] core:
/// - id-only: clipped leading text + `…`
/// - ranged: center-window `…pre + highlighted span (never clipped) + post…`;
///   relocation failure degrades to span-only, no highlight.
class QuoteBlock extends StatelessWidget {
  const QuoteBlock({super.key, required this.quote, this.target});

  final MessageQuote quote;
  final ChatMessage? target;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final target = this.target;

    String text;
    int? spanStart;
    int? spanEnd;
    if (target == null) {
      text = l10n.messageQuoteDeletedErrorMessage;
    } else {
      final full = quotePlainText(target.content);
      final start = quote.start;
      final end = quote.end;
      if (start != null && end != null) {
        final s = start < 0 ? 0 : start;
        final e = end > target.content.length ? target.content.length : end;
        if (s >= e) {
          text = quoteClipText(full);
        } else {
          final spanPlain = quotePlainText(target.content.substring(s, e));
          final win = quoteWindowText(fullPlain: full, spanPlain: spanPlain);
          if (win != null) {
            text = win.text;
            spanStart = win.spanStart;
            spanEnd = win.spanEnd;
          } else {
            text = quoteClipText(spanPlain);
          }
        }
      } else {
        text = quoteClipText(full);
      }
    }

    final mutedStyle = TextStyle(
      fontSize: 11.5,
      height: 1.25,
      color: cs.onSurface.withValues(alpha: 0.6),
    );

    if (spanStart != null && spanEnd != null && spanStart < spanEnd) {
      final pre = spanStart > 0 ? text.substring(0, spanStart) : '';
      final span = text.substring(spanStart, spanEnd);
      final post = spanEnd < text.length ? text.substring(spanEnd) : '';
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(text: pre),
            TextSpan(
              text: span,
              style: TextStyle(
                backgroundColor: cs.primary.withValues(alpha: 0.16),
              ),
            ),
            TextSpan(text: post),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: mutedStyle,
      );
    }

    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: mutedStyle,
    );
  }
}
