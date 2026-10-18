/// A citation attached to a user-originated message: the message reply
/// (docs/adr/0012-message-reply-quote.md).
///
/// The shape is deliberately offset-free. [id] names the quoted message, and
/// [text] carries the quoted span as raw markdown when the reply was made from
/// a text selection; `text == null` means the whole target message, resolved
/// live from [id]. v3 stored half-open offsets into the target's raw markdown
/// and re-located them with `subsequenceRange`; that matcher is gone (ADR-0007
/// decision 5) and a snapshot needs no relocation at all.
///
/// Persisted inside `message_rows.extras_json` under [extrasKey], so the schema
/// version does not move, and serialized as `ChatMessage.quote` in backups,
/// exports and the composer draft.
final class MessageQuote {
  const MessageQuote({required this.id, this.text});

  /// Row id of the quoted message.
  final String id;

  /// The quoted span as raw markdown, or `null` for a whole-message reply.
  final String? text;

  /// The `extras_json` key this citation persists under. Feature-prefixed, per
  /// the `MessageRows.extrasJson` discipline in `app_database.dart`.
  static const String extrasKey = 'reply.quote';

  /// Whether this citation carries its own text (a ranged reply) as opposed to
  /// referring to the whole target message.
  bool get hasText => text != null;

  Map<String, dynamic> toJson() => {'id': id, if (text != null) 'text': text};

  /// Parses [raw], or returns `null` when it does not describe a citation.
  ///
  /// Stored rows are data: a malformed value reads as "no reply" instead of
  /// throwing on load.
  static MessageQuote? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final text = raw['text'];
    return MessageQuote(
      id: id,
      text: text is String && text.isNotEmpty ? text : null,
    );
  }

  /// The citation a row's decoded `extras_json` holds, or `null`.
  static MessageQuote? decodeFromExtras(Map<String, dynamic> extras) =>
      tryParse(extras[extrasKey]);

  /// Writes this citation into the decoded [extras] map.
  void encodeIntoExtras(Map<String, dynamic> extras) {
    extras[extrasKey] = toJson();
  }

  /// This citation with its target replaced through [idMap].
  ///
  /// A copy of a conversation (fork, duplicate) mints new row ids, so a citation
  /// that kept the original id would point at a row outside the copy.
  ///
  /// A whole-message citation is nothing but that pointer, so the copy drops it
  /// (`null`). A ranged citation carries its own text and consequently survives
  /// its target's absence — the same state as a citation whose target was
  /// deleted, where the chip shows the span and the tap has nowhere to go. [id]
  /// stays because a citation is named by one and because message ids are
  /// UUIDs: no row of the copy can be mistaken for the target, and every
  /// resolution path is scoped to the conversation it runs in.
  MessageQuote? remapped(Map<String, String> idMap) {
    final next = idMap[id];
    if (next != null) return MessageQuote(id: next, text: text);
    return text == null ? null : this;
  }

  @override
  bool operator ==(Object other) =>
      other is MessageQuote && other.id == id && other.text == text;

  @override
  int get hashCode => Object.hash(id, text);

  @override
  String toString() => 'MessageQuote(id: $id, text: $text)';
}
