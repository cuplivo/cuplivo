import 'dart:convert';

import 'package:uuid/uuid.dart';

/// Structured message part — single source of truth for attachments and text.
///
/// Payload contract:
/// - `text` / `reasoning`: raw string
/// - `tool_call`: JSON string preserved as-is
/// - `assistant_round_end`: JSON reasoning-details array or `null`
/// - `image`: `{"uri","mime"?,"assetId"?,"unavailable"?}`
/// - `file`: `{"uri","name","mime"?,"assetId"?,"unavailable"?}`
/// - `subagent_result`: `{"childConversationId","elapsedMs"?,"label"?,
///   "outcome"?}` — the marker on the one message a finished subagent writes
///   into its parent conversation; `label` and `outcome` are what the divider and
///   the panel read, so an import or a sync must carry them too; the brief itself
///   is the message's `text` part
/// - `subagent_mail`: `{"fromRole","senderConversationId"}` — the marker on a
///   message one conversation in a delegation sends to the other while the work
///   is still going. It travels as `user` because that is what the receiving
///   model should read, but nobody in that conversation typed it
/// - unknown kinds: stored in [UnknownPart] and written back unchanged
/// - malformed known kinds: created only while hydrating database rows and
///   stored in [MalformedPart] for lossless write-back
sealed class MessagePart {
  const MessagePart();

  factory MessagePart.fromRow(String kind, String payload) {
    switch (kind) {
      case 'text':
        return TextPart(payload);
      case 'reasoning':
        return ReasoningPart(payload);
      case 'tool_call':
        return ToolCallPart(payload);
      case 'assistant_round_end':
        return AssistantRoundEndPart.fromPayload(payload);
      case 'image':
        return ImagePart.fromPayload(payload);
      case 'file':
        return FilePart.fromPayload(payload);
      case 'provider_auth_error':
        return ProviderAuthErrorPart.fromPayload(payload);
      case 'response_truncation':
        return ResponseTruncationPart.fromPayload(payload);
      case 'subagent_result':
        return SubagentResultPart.fromPayload(payload);
      case 'subagent_mail':
        return SubagentMailPart.fromPayload(payload);
      default:
        return UnknownPart(rawKind: kind, payload: payload);
    }
  }

  String get kind;

  String encodePayload();
}

/// Durable output-limit notice, excluded from model input like auth errors.
final class ResponseTruncationPart extends MessagePart {
  const ResponseTruncationPart({
    this.inputTokens,
    this.contextWindow,
    this.hadImages = false,
  });

  factory ResponseTruncationPart.fromPayload(String payload) {
    final data = _decodeObjectPayload(payload);
    int? tokens(String key) {
      final value = data[key];
      if (value == null) return null;
      if (value is! int || value < 0) {
        throw const _MessagePartFormatException('invalid_token_count');
      }
      return value;
    }

    return ResponseTruncationPart(
      inputTokens: tokens('inputTokens'),
      contextWindow: tokens('contextWindow'),
      hadImages: _optionalBool(data, 'hadImages'),
    );
  }

  final int? inputTokens;
  final int? contextWindow;
  final bool hadImages;

  // This is a diagnostic threshold, not a claim that images caused the limit.
  bool get contextNearLimit =>
      contextWindow != null &&
      contextWindow! > 0 &&
      inputTokens != null &&
      inputTokens! >= contextWindow! * 0.95;

  @override
  String get kind => 'response_truncation';
  @override
  String encodePayload() => jsonEncode({
    if (inputTokens != null) 'inputTokens': inputTokens,
    if (contextWindow != null) 'contextWindow': contextWindow,
    'hadImages': hadImages,
  });
  @override
  bool operator ==(Object other) =>
      other is ResponseTruncationPart &&
      other.inputTokens == inputTokens &&
      other.contextWindow == contextWindow &&
      other.hadImages == hadImages;
  @override
  int get hashCode => Object.hash(inputTokens, contextWindow, hadImages);
}

/// Durable recovery action for an OAuth failure, excluded from model input.
final class ProviderAuthErrorPart extends MessagePart {
  const ProviderAuthErrorPart({required this.providerId});
  factory ProviderAuthErrorPart.fromPayload(String payload) {
    final data = _decodeObjectPayload(payload);
    final providerId = data['providerId'];
    if (providerId is! String || providerId.isEmpty) {
      throw const _MessagePartFormatException('missing_provider_id');
    }
    return ProviderAuthErrorPart(providerId: providerId);
  }
  final String providerId;
  @override
  String get kind => 'provider_auth_error';
  @override
  String encodePayload() => jsonEncode({'providerId': providerId});
  @override
  bool operator ==(Object other) =>
      other is ProviderAuthErrorPart && other.providerId == providerId;
  @override
  int get hashCode => providerId.hashCode;
}

/// The marker on the one message a finished subagent writes into its parent.
///
/// The brief travels as that message's [TextPart], so the parent model reads an
/// ordinary user turn. Identity lives here rather than in the message id: an
/// import, a restore or a sync may rewrite ids, and the part travels with the
/// row — a rewritten id must not turn a subagent's conclusion into a user
/// utterance nobody wrote.
final class SubagentResultPart extends MessagePart {
  const SubagentResultPart({
    required this.childConversationId,
    this.elapsedMs,
    this.label,
    this.outcome,
  });

  factory SubagentResultPart.fromPayload(String payload) {
    final data = _decodeObjectPayload(payload);
    final child = data['childConversationId'];
    if (child is! String || child.isEmpty) {
      throw const _MessagePartFormatException('missing_child_conversation_id');
    }
    final elapsed = data['elapsedMs'];
    if (elapsed != null && (elapsed is! int || elapsed < 0)) {
      throw const _MessagePartFormatException('invalid_elapsed');
    }
    final label = data['label'];
    if (label != null && label is! String) {
      throw const _MessagePartFormatException('invalid_label');
    }
    final outcome = data['outcome'];
    if (outcome != null && outcome is! String) {
      throw const _MessagePartFormatException('invalid_outcome');
    }
    return SubagentResultPart(
      childConversationId: child,
      elapsedMs: elapsed as int?,
      label: label as String?,
      outcome: outcome as String?,
    );
  }

  final String childConversationId;

  /// How long the child ran. Null when the caller had no start time.
  final int? elapsedMs;

  /// What the child was called, as the model named it. The divider, the panel
  /// and the sidebar all show this same word.
  final String? label;

  /// One of `completed`, `failed`, `cancelled`, `interrupted`.
  ///
  /// Kept apart from the brief on purpose: the brief is prose for the model, so
  /// a renderer that parsed it would break the day the wording changes. A value
  /// this class does not know renders as a neutral finished state.
  final String? outcome;

  /// The result message one segment of [childConversationId] writes.
  ///
  /// A plain UUID, so nothing has to parse it; deterministic, so a second
  /// delivery of the same segment collides with the first instead of adding a
  /// row. [runId] names the segment: a delegation that was continued writes one
  /// result per turn, and the old seed (no run id) is kept only so rows written
  /// before this shape still answer.
  static String messageIdFor(String childConversationId, {String? runId}) {
    final seed = runId == null
        ? 'cuplivo/subagent-result/$childConversationId'
        : 'cuplivo/subagent-result/$childConversationId/$runId';
    return const Uuid().v5(Namespace.url.value, seed);
  }

  @override
  String get kind => 'subagent_result';

  @override
  String encodePayload() => jsonEncode({
    'childConversationId': childConversationId,
    if (elapsedMs != null) 'elapsedMs': elapsedMs,
    if (label != null) 'label': label,
    if (outcome != null) 'outcome': outcome,
  });

  @override
  bool operator ==(Object other) =>
      other is SubagentResultPart &&
      other.childConversationId == childConversationId &&
      other.elapsedMs == elapsedMs &&
      other.label == label &&
      other.outcome == outcome;

  @override
  int get hashCode =>
      Object.hash(childConversationId, elapsedMs, label, outcome);
}

/// Whether [parts] carry the notice a finished subagent wrote into its parent.
///
/// Identity is the part, never the message id: an import, a restore or a sync may
/// rewrite ids, and the part travels with the row. Everything that has to know
/// "this `user` message is not something the user typed" asks here, so the answer
/// cannot drift between the request builder, the image selector and the renderer.
bool hasSubagentResultPart(Iterable<MessagePart> parts) =>
    subagentResultPartOf(parts) != null;

/// The notice in [parts], or null when this is an ordinary message.
SubagentResultPart? subagentResultPartOf(Iterable<MessagePart> parts) {
  for (final part in parts) {
    if (part is SubagentResultPart) return part;
  }
  return null;
}

/// Who wrote a mail row, seen from the conversation holding it.
enum SubagentMailSender {
  /// The conversation that delegated the work.
  delegator,

  /// The subagent doing it.
  subagent,
}

/// The marker on a message one side of a delegation sends the other mid-work.
///
/// It travels as a `user` message because that is the role the receiving model
/// should read, but no person in that conversation typed it: the row keeps its
/// identity here for the same reason [SubagentResultPart] does — an import, a
/// restore or a sync may rewrite ids, and the part travels with the row.
final class SubagentMailPart extends MessagePart {
  const SubagentMailPart({
    required this.from,
    required this.senderConversationId,
  });

  factory SubagentMailPart.fromPayload(String payload) {
    final data = _decodeObjectPayload(payload);
    final from = switch (data['fromRole']) {
      'delegator' => SubagentMailSender.delegator,
      'subagent' => SubagentMailSender.subagent,
      _ => throw const _MessagePartFormatException('invalid_mail_sender'),
    };
    final sender = data['senderConversationId'];
    if (sender is! String || sender.isEmpty) {
      throw const _MessagePartFormatException('missing_sender_conversation_id');
    }
    return SubagentMailPart(from: from, senderConversationId: sender);
  }

  final SubagentMailSender from;

  /// The conversation the message came from.
  final String senderConversationId;

  /// The row one mail delivery writes.
  ///
  /// Deterministic on the sender and the tool call that carried it, so a retried
  /// tool call collides with its own row instead of adding a second copy. A call
  /// without an id falls back to a random one: there is nothing to be idempotent
  /// about, and two sends must not collapse into one.
  static String messageIdFor(String senderConversationId, String toolCallId) {
    final call = toolCallId.trim();
    if (call.isEmpty) return const Uuid().v4();
    return const Uuid().v5(
      Namespace.url.value,
      'cuplivo/subagent-mail/$senderConversationId/$call',
    );
  }

  @override
  String get kind => 'subagent_mail';

  @override
  String encodePayload() => jsonEncode({
    'fromRole': from.name,
    'senderConversationId': senderConversationId,
  });

  @override
  bool operator ==(Object other) =>
      other is SubagentMailPart &&
      other.from == from &&
      other.senderConversationId == senderConversationId;

  @override
  int get hashCode => Object.hash(from, senderConversationId);
}

/// Whether [parts] carry a message one side of a delegation sent the other.
bool hasSubagentMailPart(Iterable<MessagePart> parts) =>
    subagentMailPartOf(parts) != null;

/// The mail marker in [parts], or null when this is an ordinary message.
SubagentMailPart? subagentMailPartOf(Iterable<MessagePart> parts) {
  for (final part in parts) {
    if (part is SubagentMailPart) return part;
  }
  return null;
}

final class TextPart extends MessagePart {
  const TextPart(this.text);

  final String text;

  @override
  String get kind => 'text';

  @override
  String encodePayload() => text;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is TextPart && text == other.text;

  @override
  int get hashCode => text.hashCode;
}

final class ReasoningPart extends MessagePart {
  const ReasoningPart(this.text);

  final String text;

  @override
  String get kind => 'reasoning';

  @override
  String encodePayload() => text;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ReasoningPart && text == other.text;

  @override
  int get hashCode => text.hashCode;
}

final class ToolCallPart extends MessagePart {
  const ToolCallPart(this.payloadJson);

  final String payloadJson;

  /// Client-owned browser thumbnails are UI assets, not model image parts.
  String? get browserPreviewImage {
    if (!payloadJson.contains('"previewImage"')) return null;
    try {
      return browserPreviewImageFromToolEvent(jsonDecode(payloadJson));
    } on FormatException {
      return null;
    }
  }

  @override
  String get kind => 'tool_call';

  @override
  String encodePayload() => payloadJson;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolCallPart && payloadJson == other.payloadJson;

  @override
  int get hashCode => payloadJson.hashCode;
}

String? browserPreviewImageFromToolEvent(Object? event) => switch (event) {
  {
    'name': 'browser',
    'metadata': {'browser': {'previewImage': final String uri}},
  }
      when uri.trim().isNotEmpty =>
    uri,
  _ => null,
};

/// End of one model response before its client tools execute. This is durable
/// transcript structure, not visible text or a tool execution result.
final class AssistantRoundEndPart extends MessagePart {
  const AssistantRoundEndPart({this.reasoningDetails});

  factory AssistantRoundEndPart.fromPayload(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded != null && decoded is! List) {
      throw const _MessagePartFormatException('invalid_round_details');
    }
    return AssistantRoundEndPart(reasoningDetails: decoded as List<dynamic>?);
  }

  final List<dynamic>? reasoningDetails;

  @override
  String get kind => 'assistant_round_end';

  @override
  String encodePayload() => jsonEncode(reasoningDetails);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AssistantRoundEndPart &&
          encodePayload() == other.encodePayload();

  @override
  int get hashCode => encodePayload().hashCode;
}

/// Progress of a promised image whose bytes have not been written yet.
///
/// `null` on [ImagePart.state] means the bytes are there (or the part predates
/// image jobs). Unknown future values decode to `null`, so an older build still
/// shows the image instead of dropping the part.
///
/// `pending` is what the job writes; `failed` is what it writes when the picture
/// could not be made; `interrupted` is never written — the renderer derives it
/// when a persisted `pending` part has no live job behind it (the app died).
/// There is no `cancelled`: nothing in the product can cancel a job.
enum ImagePartState { pending, failed, interrupted }

final class ImagePart extends MessagePart {
  const ImagePart({
    required this.uri,
    this.mime,
    this.assetId,
    this.id,
    this.unavailable = false,
    this.jobId,
    this.state,
    this.prompt,
    this.model,
    this.failureReason,
    this.durationMs,
  });

  factory ImagePart.fromPayload(String payload) {
    final map = _decodeObjectPayload(payload);
    final uri = map['uri'];
    if (uri is! String || uri.isEmpty) {
      throw const _MessagePartFormatException('missing_uri');
    }
    return ImagePart(
      uri: uri,
      mime: _optionalString(map, 'mime'),
      assetId: _optionalString(map, 'assetId'),
      unavailable: _optionalBool(map, 'unavailable'),
      jobId: _optionalString(map, 'jobId'),
      state: _decodeImagePartState(_optionalString(map, 'state')),
      prompt: _optionalString(map, 'prompt'),
      model: _optionalString(map, 'model'),
      failureReason: _optionalString(map, 'failureReason'),
      durationMs: _optionalInt(map, 'durationMs'),
    );
  }

  final String uri;
  final String? mime;
  final String? assetId;

  /// Stream image id. Runtime-only — not written to [encodePayload].
  final String? id;
  final bool unavailable;

  /// The job that will fill [uri]; written so a restart can tell "still
  /// painting" from "interrupted".
  final String? jobId;

  /// `null` once the bytes exist.
  final ImagePartState? state;

  /// What was asked for. Kept on the part so the panel can still show it after a
  /// restart, when no live job remembers the prompt.
  final String? prompt;

  /// `providerId::modelId` that drew it. The panel names it after a restart,
  /// when the resolved binding is gone.
  final String? model;

  /// Why the attempt failed, in words a person can act on. Kept on the part so
  /// a failed picture still explains itself after a restart.
  final String? failureReason;

  /// How long the attempt took, kept on the part so the header still reads
  /// `(14.5s)` after a restart instead of a bare title. Milliseconds.
  final int? durationMs;

  /// The duration as a [Duration], or null when this picture never reported one.
  Duration? get duration =>
      durationMs == null ? null : Duration(milliseconds: durationMs!);

  /// The same picture with its location or availability replaced.
  ///
  /// Restore and path-rewrite passes touch every attachment; rebuilding the part
  /// field by field there is how an illustration lost its job state, prompt,
  /// model, reason and duration. `state` is not cosmetic: `hasBytes` derives
  /// from it, so a stripped `pending` part would be sent to a provider as if its
  /// bytes existed.
  ImagePart copyWith({String? uri, bool? unavailable, String? mime}) {
    return ImagePart(
      uri: uri ?? this.uri,
      mime: mime ?? this.mime,
      assetId: assetId,
      id: id,
      unavailable: unavailable ?? this.unavailable,
      jobId: jobId,
      state: state,
      prompt: prompt,
      model: model,
      failureReason: failureReason,
      durationMs: durationMs,
    );
  }

  /// Whether there are bytes to send.
  ///
  /// A part with a [state] is a promise from an image job: the uri is already
  /// reserved, but the file it names does not exist yet. Nothing may hand that
  /// to a model — there is no picture to encode — so every outbound path asks
  /// this instead of re-deriving "is this thing real" from the uri. Whether the
  /// file passed [unavailable] once it *was* written is a separate question.
  bool get hasBytes => state == null;

  /// The same image at a new stage. [state] `null` means the bytes are here;
  /// [uri] moves to wherever the bytes actually landed; [failureReason] lets a
  /// live job explain a failure the persisted snapshot never saw.
  ImagePart withState(
    ImagePartState? state, {
    String? uri,
    String? failureReason,
  }) {
    return ImagePart(
      uri: uri ?? this.uri,
      mime: mime,
      assetId: assetId,
      id: id,
      unavailable: unavailable,
      jobId: jobId,
      state: state,
      prompt: prompt,
      model: model,
      failureReason: failureReason ?? this.failureReason,
      durationMs: durationMs,
    );
  }

  @override
  String get kind => 'image';

  @override
  String encodePayload() => jsonEncode({
    'uri': uri,
    if (mime != null) 'mime': mime,
    if (assetId != null) 'assetId': assetId,
    if (unavailable) 'unavailable': true,
    if (jobId != null) 'jobId': jobId,
    if (state != null) 'state': state!.name,
    if (prompt != null) 'prompt': prompt,
    if (model != null) 'model': model,
    if (failureReason != null) 'failureReason': failureReason,
    if (durationMs != null) 'durationMs': durationMs,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImagePart &&
          uri == other.uri &&
          mime == other.mime &&
          assetId == other.assetId &&
          id == other.id &&
          unavailable == other.unavailable &&
          jobId == other.jobId &&
          state == other.state &&
          prompt == other.prompt &&
          model == other.model &&
          failureReason == other.failureReason &&
          durationMs == other.durationMs;

  @override
  int get hashCode => Object.hash(
    uri,
    mime,
    assetId,
    id,
    unavailable,
    jobId,
    state,
    prompt,
    model,
    failureReason,
    durationMs,
  );
}

final class FilePart extends MessagePart {
  const FilePart({
    required this.uri,
    required this.name,
    this.mime,
    this.assetId,
    this.unavailable = false,
  });

  factory FilePart.fromPayload(String payload) {
    final map = _decodeObjectPayload(payload);
    final uri = map['uri'];
    final name = map['name'];
    if (uri is! String || uri.isEmpty) {
      throw const _MessagePartFormatException('missing_uri');
    }
    if (name is! String || name.isEmpty) {
      throw const _MessagePartFormatException('missing_name');
    }
    return FilePart(
      uri: uri,
      name: name,
      mime: _optionalString(map, 'mime'),
      assetId: _optionalString(map, 'assetId'),
      unavailable: _optionalBool(map, 'unavailable'),
    );
  }

  final String uri;
  final String name;
  final String? mime;
  final String? assetId;
  final bool unavailable;

  @override
  String get kind => 'file';

  @override
  String encodePayload() => jsonEncode({
    'uri': uri,
    'name': name,
    if (mime != null) 'mime': mime,
    if (assetId != null) 'assetId': assetId,
    if (unavailable) 'unavailable': true,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FilePart &&
          uri == other.uri &&
          name == other.name &&
          mime == other.mime &&
          assetId == other.assetId &&
          unavailable == other.unavailable;

  @override
  int get hashCode => Object.hash(uri, name, mime, assetId, unavailable);
}

/// Forward-compatible carrier for kinds this build does not understand.
final class UnknownPart extends MessagePart {
  const UnknownPart({required this.rawKind, required this.payload});

  final String rawKind;
  final String payload;

  @override
  String get kind => rawKind;

  @override
  String encodePayload() => payload;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UnknownPart &&
          rawKind == other.rawKind &&
          payload == other.payload;

  @override
  int get hashCode => Object.hash(rawKind, payload);
}

/// A known part kind whose persisted payload cannot be parsed.
///
/// Unlike [UnknownPart], an attachment-shaped malformed part may still own an
/// asset reference. Database hydration uses this carrier to isolate corrupt
/// rows while preserving their exact payload for a later repair or write-back.
final class MalformedPart extends MessagePart {
  const MalformedPart({
    required this.rawKind,
    required this.rawPayload,
    required this.parseError,
  });

  final String rawKind;
  final String rawPayload;
  final String parseError;

  bool get isAttachmentKind => rawKind == 'image' || rawKind == 'file';

  @override
  String get kind => rawKind;

  @override
  String encodePayload() => rawPayload;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MalformedPart &&
          rawKind == other.rawKind &&
          rawPayload == other.rawPayload &&
          parseError == other.parseError;

  @override
  int get hashCode => Object.hash(rawKind, rawPayload, parseError);
}

String messagePartParseErrorCategory(FormatException error) {
  return error is _MessagePartFormatException
      ? error.category
      : 'invalid_payload';
}

final class _MessagePartFormatException extends FormatException {
  const _MessagePartFormatException(this.category) : super(category);

  final String category;
}

Map<String, dynamic> _decodeObjectPayload(String payload) {
  late final Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } on FormatException {
    throw const _MessagePartFormatException('invalid_json');
  }
  if (decoded is! Map) {
    throw const _MessagePartFormatException('not_object');
  }
  return Map<String, dynamic>.from(decoded);
}

String? _optionalString(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String) {
    final category = switch (key) {
      'mime' => 'invalid_mime',
      'assetId' => 'invalid_asset_id',
      _ => 'invalid_optional_string',
    };
    throw _MessagePartFormatException(category);
  }
  return value;
}

bool _optionalBool(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return false;
  if (value is! bool) {
    throw const _MessagePartFormatException('invalid_unavailable');
  }
  return value;
}

int? _optionalInt(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is! int || value < 0) {
    throw const _MessagePartFormatException('invalid_duration');
  }
  return value;
}

/// An unknown value is not a format error: a newer build may write a state this
/// one does not know, and the image itself is still described by [ImagePart.uri].
ImagePartState? _decodeImagePartState(String? raw) {
  if (raw == null) return null;
  for (final state in ImagePartState.values) {
    if (state.name == raw) return state;
  }
  return null;
}

/// Whether persisted split triples can drive the historical interleaving
/// renderer.
///
/// Empty arrays, length mismatches, negative values, and count regressions
/// are not usable. Those messages must keep [MessagePart] arrival order.
bool contentSplitsAreUsable(
  List<int>? offsets,
  List<int>? reasoningCounts,
  List<int>? toolCounts,
) {
  if (offsets == null || reasoningCounts == null || toolCounts == null) {
    return false;
  }
  if (offsets.isEmpty ||
      offsets.length != reasoningCounts.length ||
      offsets.length != toolCounts.length) {
    return false;
  }

  var previousOffset = 0;
  var previousReasoning = 0;
  var previousTool = 0;
  for (var i = 0; i < offsets.length; i++) {
    final offset = offsets[i];
    final reasoning = reasoningCounts[i];
    final tool = toolCounts[i];
    if (offset < 0 || reasoning < 0 || tool < 0) {
      return false;
    }
    if (i > 0 &&
        (offset < previousOffset ||
            reasoning < previousReasoning ||
            tool < previousTool)) {
      return false;
    }
    previousOffset = offset;
    previousReasoning = reasoning;
    previousTool = tool;
  }
  return true;
}

/// Parse persisted split triples only when they pass [contentSplitsAreUsable].
///
/// Length mismatches are rejected instead of being truncated down to the
/// shortest array, so a broken payload cannot be repaired into a "valid"
/// interleaving.
({List<int> offsets, List<int> reasoningCounts, List<int> toolCounts})?
tryParseContentSplits(dynamic raw) {
  if (raw is! Map) return null;
  final json = raw is Map<String, dynamic> ? raw : raw.cast<String, dynamic>();
  final offsets = _tryContentSplitIntList(json['offsets']);
  final reasoningCounts = _tryContentSplitIntList(json['reasoningCounts']);
  final toolCounts = _tryContentSplitIntList(json['toolCounts']);
  if (!contentSplitsAreUsable(offsets, reasoningCounts, toolCounts)) {
    return null;
  }
  return (
    offsets: offsets!,
    reasoningCounts: reasoningCounts!,
    toolCounts: toolCounts!,
  );
}

List<int>? _tryContentSplitIntList(dynamic value) {
  if (value == null) return const <int>[];
  if (value is! List) return null;
  final out = <int>[];
  for (final item in value) {
    if (item is int) {
      out.add(item);
    } else if (item is num && item == item.roundToDouble()) {
      out.add(item.toInt());
    } else {
      return null;
    }
  }
  return out;
}

/// Whether structurally valid split triples actually cover the timeline.
///
/// Offsets must stay within [contentLength], each target count pair must
/// appear in order on the rendered steps, and the last target must consume
/// every step. Incomplete coverage would otherwise append leftover
/// reasoning/tool cards after the trailing body.
bool contentSplitsMatchTimeline({
  required List<int> offsets,
  required List<int> reasoningCounts,
  required List<int> toolCounts,
  required int contentLength,
  required List<int> stepReasoningCounts,
  required List<int> stepToolCounts,
}) {
  if (!contentSplitsAreUsable(offsets, reasoningCounts, toolCounts)) {
    return false;
  }
  if (stepReasoningCounts.length != stepToolCounts.length ||
      stepReasoningCounts.isEmpty) {
    return false;
  }

  var stepIndex = 0;
  for (var i = 0; i < offsets.length; i++) {
    if (offsets[i] > contentLength) return false;
    final targetReasoning = reasoningCounts[i];
    final targetTool = toolCounts[i];
    var found = false;
    while (stepIndex < stepReasoningCounts.length) {
      final reasoningAfter = stepReasoningCounts[stepIndex];
      final toolAfter = stepToolCounts[stepIndex];
      stepIndex++;
      if (reasoningAfter == targetReasoning && toolAfter == targetTool) {
        found = true;
        break;
      }
    }
    if (!found) return false;
  }
  return stepIndex == stepReasoningCounts.length;
}

/// Whether the assistant bubble should walk [parts] instead of contentSplits.
///
/// Historical rows keep a flat `[reasoning, tools…, body]` layout plus
/// persisted split triples that reconstruct interleaving. Those stay on the
/// split renderer. New streams persist [ReasoningPart] / [ToolCallPart]
/// (and generated [ImagePart]s) in arrival order and have no splits.
bool renderAssistantFromParts({
  required List<MessagePart> parts,
  required bool hasContentSplits,
}) {
  if (hasContentSplits) return false;
  for (final part in parts) {
    if (part is ReasoningPart || part is ToolCallPart) return true;
  }
  return parts.any((part) => part is ImagePart);
}
