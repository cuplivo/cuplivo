/// Citation reference attached to a user-originated message (message reply,
/// issue #312). Persists as JSON in `message_rows.quote_json` and rides the
/// `chat_draft_v1` draft blob. The plain-text `toJson`/`fromJson` double as
/// the draft-blob serialization.
///
/// `[start, end)` index the target's RAW markdown content (markdown-space, half
/// open). A range selects the answered span; the display and the `<reply-to>`
/// API injection consume the same plain-text extraction (see
/// `lib/utils/quote_plain_text.dart`).
class MessageQuote {
  final String id;

  /// Half-open start offset into the target's raw markdown content.
  final int? start;

  /// Half-open end offset into the target's raw markdown content.
  final int? end;

  const MessageQuote({required this.id, this.start, this.end});

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      if (start != null) 'start': start,
      if (end != null) 'end': end,
    };
  }

  factory MessageQuote.fromJson(Map<String, dynamic> json) {
    final rawId = json['id'];
    if (rawId is! String || rawId.isEmpty) {
      throw const FormatException('MessageQuote requires a non-empty id');
    }
    return MessageQuote(
      id: rawId,
      start: (json['start'] as num?)?.toInt(),
      end: (json['end'] as num?)?.toInt(),
    );
  }
}
