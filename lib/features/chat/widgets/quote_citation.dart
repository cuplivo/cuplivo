import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/message_quote.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../utils/reply_citation_label.dart';

/// The one-line reply citation that sits above a message's content,
/// QQ-style (docs/adr/0012).
///
/// A ranged citation carries its own markdown, so it shows that text whatever
/// happened to its target — the target only feeds the tap that jumps to it. A
/// whole-message citation has no text of its own: it shows [target]'s rendered
/// text. [target] is the revision the cited message's **slot** shows now
/// (`docs/adr/0012`), so a version switch or a regeneration does not turn the
/// chip into a stub, and the jump still lands. The localized stub is for the
/// case that means it — no target resolved at all (deleted, or outside the
/// loaded window); a target that resolved but renders to nothing shows the
/// item's own label instead, because the message is right there.
class QuoteCitation extends StatefulWidget {
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
  State<QuoteCitation> createState() => _QuoteCitationState();
}

class _QuoteCitationState extends State<QuoteCitation> {
  /// The inputs the cached [_label] was derived from.
  Object? _labelKey;
  String? _label;

  /// The citation's text in display space, derived at most once per input.
  ///
  /// `replyCitationLabel` walks the whole citation through the Markdown IR, and
  /// a bubble is rebuilt on every stream publish; deriving this in `build`
  /// re-walks a long quoted message ~20 times a second to produce one line of
  /// 120 code units. The key holds everything that walk reads — the source, the
  /// streaming flag, and the four settings `markdownDocument` consults — so a
  /// settled citation is derived once per widget instance and a settings change
  /// still invalidates it. Comparing the key is O(1) while the source string is
  /// the same instance, which is what a rebuild hands back.
  String? _labelFor(String? source) {
    if (source == null) return null;
    final settings = context.read<SettingsProvider>();
    final key = (
      source,
      settings.enableMathRendering,
      settings.enableDollarLatex,
      settings.autoCollapseCodeBlock,
      settings.autoCollapseCodeBlockLines,
    );
    if (key != _labelKey) {
      _labelKey = key;
      _label = replyCitationLabel(source, settings: settings);
    }
    return _label;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final own = widget.quote.text;
    final resolved = widget.target;
    final label = _labelFor(own ?? resolved?.content);
    // A target that resolved but renders to nothing — an image-only message, an
    // answer that is only a tool call — still exists and is still tappable: the
    // "original message unavailable" stub would misdescribe it. Such a citation
    // falls back to the item's own label, which is exactly what the composer's
    // preview row shows for it (docs/adr/0012). The stub stays for the one case
    // that means it: a whole-message citation whose target cannot be resolved at
    // all.
    final shown = label == null
        ? l10n.messageQuoteTargetMissing
        : (label.isEmpty ? l10n.messageMoreSheetReply : label);

    final muted = cs.onSurface.withValues(alpha: 0.55);
    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        // The citation belongs to the right-aligned user turn it sits above, so
        // it leans right whatever box a caller hands it (docs/adr/0012).
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Icon(Lucide.Reply, size: 13, color: muted),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              shown,
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
