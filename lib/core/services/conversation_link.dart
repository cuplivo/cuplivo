import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;

/// An OS-registered pointer to one conversation, optionally anchored on one
/// message: `cuplivo://conversation/<conversationId>[?message=<messageId>]`.
///
/// `cuplivo` is the app scheme, so the OS opens this app when the link is
/// tapped (ADR-0001); `kelivo://` is the content namespace and is never
/// registered with the OS, so it is deliberately not accepted here.
///
/// A link is a pointer, not a copy: it resolves only where the conversation
/// exists — the install that copied it, or a device LAN sync carried it to
/// (merged rows keep their ids). The same URL crosses the mobile bridges whole, so
/// the Live Activity widget's id and a copied link are read by one grammar.
class ConversationLink {
  const ConversationLink({required this.conversationId, this.messageId});

  static const String scheme = 'cuplivo';
  static const String host = 'conversation';
  static const String messageParameter = 'message';
  static const int _maxIdLength = 200;

  final String conversationId;

  /// The message the link points at, or null for the conversation itself.
  final String? messageId;

  /// True where the OS has this scheme registered, i.e. where a link this app
  /// copies actually opens this app when the user taps it. Android registers
  /// `cuplivo` in `AndroidManifest.xml` and iOS in `ios/Runner/Info.plist`;
  /// enabling another platform means registering the scheme *and* adding it
  /// here (macOS `Runner/Info.plist`, the Windows installer's registry entry,
  /// Linux's `.desktop` MimeType).
  static bool get osRegistered =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  /// The canonical string a user copies. Encoded with [Uri.encodeComponent] so
  /// no id can introduce a path separator or a second parameter.
  ///
  /// Only ever called for ids [supportsId] accepts; the asserts are the
  /// tripwire, and the copy entries are hidden where they would fire.
  String get url {
    assert(supportsId(conversationId), 'a link cannot carry this id');
    final path = Uri.encodeComponent(conversationId);
    final message = messageId;
    assert(
      message == null || supportsId(message),
      'a link cannot carry this message id',
    );
    if (message == null) return '$scheme://$host/$path';
    return '$scheme://$host/$path?$messageParameter='
        '${Uri.encodeComponent(message)}';
  }

  /// Parses a link, or returns null when [raw] is not one. Never throws: a
  /// link is untrusted input (any web page can fire the scheme).
  static ConversationLink? tryParse(String raw) {
    final text = raw.trim();
    const prefix = '$scheme://';
    if (text.length <= prefix.length) return null;
    if (text.substring(0, prefix.length).toLowerCase() != prefix) return null;
    // A fragment is not part of the grammar; ignoring it would let two
    // different strings claim the same target.
    final rest = text.substring(prefix.length);
    if (rest.contains('#')) return null;

    final queryStart = rest.indexOf('?');
    final authorityAndPath = queryStart < 0
        ? rest
        : rest.substring(0, queryStart);
    final query = queryStart < 0 ? null : rest.substring(queryStart + 1);

    // `<host>/<one segment>` only: userinfo, a port, an empty host, a missing
    // or multi-segment path all fail.
    final slash = authorityAndPath.indexOf('/');
    if (slash < 0) return null;
    final authority = authorityAndPath.substring(0, slash);
    if (authority.contains('@') || authority.contains(':')) return null;
    if (authority.toLowerCase() != host) return null;
    final rawPath = authorityAndPath.substring(slash + 1);
    if (rawPath.isEmpty || rawPath.contains('/') || rawPath.contains(r'\')) {
      return null;
    }
    final conversationId = _decodeId(rawPath);
    if (conversationId == null) return null;

    String? subMessage;
    if (query != null && query.isNotEmpty) {
      for (final part in query.split('&')) {
        final separator = part.indexOf('=');
        if (separator <= 0) return null;
        if (part.substring(0, separator) != messageParameter) return null;
        if (subMessage != null) return null;
        subMessage = _decodeId(part.substring(separator + 1));
        if (subMessage == null) return null;
      }
    }

    return ConversationLink(
      conversationId: conversationId,
      messageId: subMessage,
    );
  }

  /// Percent-decodes one id. Raw non-ASCII passes through, and a `+` stays a
  /// `+` (a link this app writes encodes it as `%2B`), so the string a user
  /// copies always round-trips to the same id.
  static String? _decodeId(String raw) {
    if (!raw.contains('%')) return supportsId(raw) ? raw : null;
    final normalized = StringBuffer();
    for (final rune in raw.runes) {
      if (rune > 127) {
        normalized.write(Uri.encodeComponent(String.fromCharCode(rune)));
      } else {
        normalized.writeCharCode(rune);
      }
    }
    final String decoded;
    try {
      decoded = Uri.decodeComponent(normalized.toString());
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
    return supportsId(decoded) ? decoded : null;
  }

  /// Whether the grammar can carry [id] — the one rule [url] and [tryParse]
  /// share, so a link this app writes always parses back to the same ids.
  ///
  /// A conversation or message id is an opaque row key: it is only ever looked
  /// up, never a path or a command, so the grammar constrains *structure*
  /// (scheme, host, one segment, no fragment, one known parameter) and leaves
  /// the id's characters alone. Ids carrying a space, `/`, `\` or a control
  /// character round-trip through percent-encoding like any other. The length
  /// cap bounds what an untrusted link can hand to a lookup, and it is the only
  /// reason a stored id has no link — the copy entries are hidden for it.
  static bool supportsId(String id) =>
      id.isNotEmpty && id.length <= _maxIdLength;
}
