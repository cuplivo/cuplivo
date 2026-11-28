import 'package:flutter/foundation.dart';

import '../../../core/models/chat_message.dart';
import '../../../utils/source_text_map.dart';

/// One selection surface and the actions it supports.
///
/// A message bubble and a rendered document share the menu, the quick toolbar
/// and the translation panel. What differs is whether there is a message to
/// quote, and whether the selection's offsets point into a message body or into
/// the document itself.
@immutable
class SelectionSession {
  const SelectionSession({
    required this.source,
    this.sourceMap,
    this.message,
    this.quoteTextOnly = false,
    this.onQuoteSelected,
  });

  /// A rendered document with no message behind it: everything is selectable
  /// and translatable, but there is nothing to quote.
  const SelectionSession.document({required this.source})
    : sourceMap = null,
      message = null,
      quoteTextOnly = false,
      onQuoteSelected = null;

  /// The Markdown the selection's source offsets index into.
  final String source;
  final SourceTextMap? sourceMap;
  final ChatMessage? message;

  /// Capture a quote chip without linking its text to message body offsets.
  final bool quoteTextOnly;
  final VoidCallback? onQuoteSelected;

  bool get canQuote => message != null;
}
