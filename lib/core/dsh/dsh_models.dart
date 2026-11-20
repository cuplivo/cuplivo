/// Domain models for the DeepSeek Harness client.
///
/// Everything here is parsed tolerantly: unknown keys are ignored, a malformed
/// member degrades to a default instead of throwing, and models that may gain
/// plugin-contributed fields keep their `raw` JSON. DSH adds fields and
/// projection keys additively; a strict decoder would break on a newer Host.
library;

import 'dart:convert';

// =============================================================================
// Tolerant JSON helpers (public: the feature layer parses plugin JSON with them)
// =============================================================================

Map<String, Object?> jsonMap(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const {};

List<Object?> jsonList(Object? value) => value is List ? value : const [];

String? jsonString(Object? value) => value is String ? value : null;

int? jsonInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

double? jsonDouble(Object? value) {
  if (value is num) return value.toDouble();
  return null;
}

bool? jsonBool(Object? value) => value is bool ? value : null;

DateTime? jsonEpochMs(Object? value) {
  final ms = jsonInt(value);
  return ms == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

DateTime? jsonIsoDateTime(Object? value) {
  final text = jsonString(value);
  if (text == null || text.isEmpty) return null;
  return DateTime.tryParse(text);
}

List<String> jsonStringList(Object? value) =>
    jsonList(value).whereType<String>().toList(growable: false);

Object? tryDecodeJson(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

// =============================================================================
// Messages, content parts and usage
// =============================================================================

/// One content block of a durable message.
sealed class DshPart {
  const DshPart();

  static DshPart fromJson(Object? json) {
    final map = jsonMap(json);
    switch (jsonString(map['type'])) {
      case 'text':
        return DshTextPart(jsonString(map['text']) ?? '');
      case 'reasoning':
        return DshReasoningPart(jsonString(map['text']) ?? '');
      case 'image':
        return DshImagePart(
          DshImageAttachment.fromJson(map['attachment']),
          offloaded: map['offloaded'] == true,
        );
      case 'file':
        return DshFilePart(DshFileAttachment.fromJson(map['attachment']));
      case 'tool-call':
        return DshToolCallPart(
          id: jsonString(map['id']) ?? '',
          name: jsonString(map['name']) ?? '',
          arguments: jsonString(map['arguments']) ?? '',
        );
      default:
        return DshUnknownPart(jsonString(map['type']) ?? '', map);
    }
  }

  static List<DshPart> listFromJson(Object? json) =>
      jsonList(json).map(DshPart.fromJson).toList(growable: false);
}

final class DshTextPart extends DshPart {
  const DshTextPart(this.text);
  final String text;
}

/// Model reasoning ("thinking"); render collapsed, never as the answer.
final class DshReasoningPart extends DshPart {
  const DshReasoningPart(this.text);
  final String text;
}

final class DshImagePart extends DshPart {
  const DshImagePart(this.attachment, {this.offloaded = false});
  final DshImageAttachment attachment;
  final bool offloaded;
}

final class DshFilePart extends DshPart {
  const DshFilePart(this.attachment);
  final DshFileAttachment attachment;
}

/// A tool invocation inside an assistant message; [arguments] is the raw JSON
/// text exactly as the model produced it (possibly partial while streaming).
final class DshToolCallPart extends DshPart {
  const DshToolCallPart({
    required this.id,
    required this.name,
    required this.arguments,
  });
  final String id;
  final String name;
  final String arguments;

  Map<String, Object?>? get decodedArguments {
    if (arguments.isEmpty) return null;
    final decoded = tryDecodeJson(arguments);
    return decoded is Map ? jsonMap(decoded) : null;
  }
}

/// Plugin- or future-provided block types (`tool-addition`, …).
final class DshUnknownPart extends DshPart {
  const DshUnknownPart(this.type, this.raw);
  final String type;
  final Map<String, Object?> raw;
}

/// Host content-addressed image reference (`sha256:<hex>`); fetch bytes with
/// `session/attachment`.
class DshImageAttachment {
  const DshImageAttachment({
    required this.attachmentId,
    required this.mediaType,
    this.bytes,
    this.width,
    this.height,
    this.name,
  });

  factory DshImageAttachment.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshImageAttachment(
      attachmentId: jsonString(map['attachmentId']) ?? '',
      mediaType: jsonString(map['mediaType']) ?? 'application/octet-stream',
      bytes: jsonInt(map['bytes']),
      width: jsonInt(map['width']),
      height: jsonInt(map['height']),
      name: jsonString(map['name']),
    );
  }

  final String attachmentId;
  final String mediaType;
  final int? bytes;
  final int? width;
  final int? height;
  final String? name;

  /// Wire form for `session/attachment` (the full reference is required).
  Map<String, Object?> toJson() => {
    'attachmentId': attachmentId,
    'mediaType': mediaType,
    if (bytes != null) 'bytes': bytes,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (name != null) 'name': name,
  };
}

class DshFileAttachment {
  const DshFileAttachment({required this.attachmentId, this.name, this.bytes});

  factory DshFileAttachment.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshFileAttachment(
      attachmentId: jsonString(map['attachmentId']) ?? '',
      name: jsonString(map['name']),
      bytes: jsonInt(map['bytes']),
    );
  }

  final String attachmentId;
  final String? name;
  final int? bytes;
}

/// Where a message came from (`source` on the wire). Only `user` is a human
/// prompt row; everything else is injected context.
class DshMessageSource {
  const DshMessageSource({
    required this.kind,
    this.requestId,
    this.raw = const {},
  });

  factory DshMessageSource.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshMessageSource(
      kind: jsonString(map['kind']) ?? 'unknown',
      requestId: jsonString(map['rpcId']) ?? jsonString(map['requestId']),
      raw: map,
    );
  }

  /// `user`, `model`, `tool`, `runtime-context`, `time-context`, …
  final String kind;

  /// Client `requestId` of the prompt that produced this message.
  final String? requestId;
  final Map<String, Object?> raw;
}

/// One durable message (`role`-discriminated on the wire).
class DshMessage {
  const DshMessage({
    required this.id,
    required this.role,
    required this.parts,
    required this.source,
    this.raw = const {},
  });

  factory DshMessage.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshMessage(
      id: jsonString(map['id']) ?? '',
      role: jsonString(map['role']) ?? 'unknown',
      parts: DshPart.listFromJson(map['content'] ?? map['parts']),
      source: DshMessageSource.fromJson(map['source']),
      raw: map,
    );
  }

  final String id;
  final String role;
  final List<DshPart> parts;
  final DshMessageSource source;
  final Map<String, Object?> raw;

  String get text => parts.whereType<DshTextPart>().map((p) => p.text).join();

  String get reasoning =>
      parts.whereType<DshReasoningPart>().map((p) => p.text).join();

  List<DshImageAttachment> get images => parts
      .whereType<DshImagePart>()
      .map((p) => p.attachment)
      .toList(growable: false);

  List<DshFileAttachment> get files => parts
      .whereType<DshFilePart>()
      .map((p) => p.attachment)
      .toList(growable: false);

  List<DshToolCallPart> get toolCalls =>
      parts.whereType<DshToolCallPart>().toList(growable: false);
}

/// Step token accounting carried by `assistant/message.usage` and the live
/// `usage` stream chunk.
class DshTokenUsage {
  const DshTokenUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.totalTokens,
  });

  factory DshTokenUsage.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshTokenUsage(
      inputTokens: jsonInt(map['inputTokens']) ?? 0,
      outputTokens: jsonInt(map['outputTokens']) ?? 0,
      cacheReadTokens: jsonInt(map['cacheReadTokens']) ?? 0,
      cacheWriteTokens: jsonInt(map['cacheWriteTokens']) ?? 0,
      totalTokens: jsonInt(map['totalTokens']),
    );
  }

  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final int? totalTokens;

  int get effectiveTotal =>
      totalTokens ??
      inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens;
}

/// Session-level usage projection (different shape from [DshTokenUsage]: no
/// `inputTokens`/`totalTokens`, it is `uncachedInputTokens`).
class DshSessionUsage {
  const DshSessionUsage({
    this.uncachedInputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
  });

  factory DshSessionUsage.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshSessionUsage(
      uncachedInputTokens: jsonInt(map['uncachedInputTokens']) ?? 0,
      outputTokens: jsonInt(map['outputTokens']) ?? 0,
      cacheReadTokens: jsonInt(map['cacheReadTokens']) ?? 0,
      cacheWriteTokens: jsonInt(map['cacheWriteTokens']) ?? 0,
    );
  }

  final int uncachedInputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;

  int get totalTokens =>
      uncachedInputTokens + outputTokens + cacheReadTokens + cacheWriteTokens;
}

/// Turn-level model failure (`turn/end.reason.error`, stream `finish.failure`).
class DshLlmFailure {
  const DshLlmFailure({
    required this.message,
    this.code,
    this.status,
    this.name,
    this.raw = const {},
  });

  factory DshLlmFailure.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshLlmFailure(
      message: jsonString(map['message']) ?? 'The model call failed',
      code: jsonString(map['code']),
      status: jsonInt(map['status']),
      name: jsonString(map['name']),
      raw: map,
    );
  }

  final String message;
  final String? code;
  final int? status;
  final String? name;
  final Map<String, Object?> raw;
}

// =============================================================================
// Sessions
// =============================================================================

/// Projection block carried by a session list row.
///
/// `kind: 'sequenced'` values are complete at [asOfSeq] and comparable with
/// projection baselines from the same connection; `kind: 'cached'` is a cold
/// summary watermark that must not be compared with other sessions.
class DshProjectionHints {
  const DshProjectionHints({
    required this.kind,
    required this.asOfSeq,
    required this.values,
  });

  factory DshProjectionHints.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshProjectionHints(
      kind: jsonString(map['kind']) ?? 'cached',
      asOfSeq: jsonInt(map['asOfSeq']) ?? -1,
      values: jsonMap(map['values']),
    );
  }

  final String kind;
  final int asOfSeq;
  final Map<String, Object?> values;

  bool get isSequenced => kind == 'sequenced';

  Object? operator [](String key) => values[key];
}

/// One `session/list` row.
class DshSessionSummary {
  const DshSessionSummary({
    required this.sessionId,
    required this.updatedAt,
    required this.raw,
    this.running = false,
    this.blank = true,
    this.agentAvailable = false,
    this.cwd,
    this.formatStatus,
    this.parentSessionId,
    this.origin,
    this.projections,
  });

  factory DshSessionSummary.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshSessionSummary(
      sessionId: jsonString(map['sessionId']) ?? '',
      updatedAt:
          jsonEpochMs(map['updatedAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      running: map['running'] == true,
      blank: map['blank'] != false,
      agentAvailable: map['agentAvailable'] == true,
      cwd: jsonString(map['cwd']),
      formatStatus: jsonString(map['formatStatus']),
      parentSessionId: jsonString(map['parentSessionId']),
      origin: jsonString(map['origin']),
      projections: map['projections'] == null
          ? null
          : DshProjectionHints.fromJson(map['projections']),
      raw: map,
    );
  }

  final String sessionId;
  final DateTime updatedAt;
  final bool running;
  final bool blank;
  final bool agentAvailable;
  final String? cwd;
  final String? formatStatus;
  final String? parentSessionId;
  final String? origin;
  final DshProjectionHints? projections;
  final Map<String, Object?> raw;

  /// Row title from the summary projections; null means "new chat".
  String? get title => jsonString(projections?.values['title']);

  /// The preset this Session runs, from `agentPreset` projections; null when
  /// the deployment composes no preset roster or the Session recorded none.
  String? get agentPreset => jsonString(projections?.values['agentPreset']);

  DshModelSelection? get nextModel {
    final model = jsonMap(projections?.values['modelSelection']);
    final next = jsonMap(model['next']);
    return next.isEmpty ? null : DshModelSelection.fromJson(next);
  }

  DshSessionUsage? get usage {
    final value = projections?.values['tokenUsage'];
    return value == null ? null : DshSessionUsage.fromJson(value);
  }

  bool get migrationRequired => formatStatus == 'migration-required';
}

/// Result of `session/create` (the returned id is authoritative: the Host may
/// reuse a stored blank session).
class DshSessionCreated {
  const DshSessionCreated({required this.sessionId, this.agentPreset});

  factory DshSessionCreated.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshSessionCreated(
      sessionId: jsonString(map['sessionId']) ?? '',
      agentPreset: jsonString(map['agentPreset']),
    );
  }

  final String sessionId;
  final String? agentPreset;
}

/// Session log header delivered by a `session/follow` snapshot.
class DshSessionHeader {
  const DshSessionHeader({
    required this.id,
    required this.version,
    required this.createdAt,
    this.cwd,
    this.isSeeded = false,
    this.agentPreset,
    this.parentSessionId,
    this.origin,
    this.raw = const {},
  });

  factory DshSessionHeader.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshSessionHeader(
      id: jsonString(map['id']) ?? '',
      version: jsonInt(map['version']) ?? 0,
      createdAt:
          jsonEpochMs(map['createdAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      cwd: jsonString(map['cwd']),
      isSeeded: map['isSeeded'] == true,
      agentPreset: jsonString(map['agentPreset']),
      parentSessionId: jsonString(map['parentSessionId']),
      origin: jsonString(map['origin']),
      raw: map,
    );
  }

  final String id;

  /// Session log format version (4 on DSH 0.2.2).
  final int version;
  final DateTime createdAt;
  final String? cwd;
  final bool isSeeded;
  final String? agentPreset;
  final String? parentSessionId;
  final String? origin;
  final Map<String, Object?> raw;

  /// Logs newer than the vocabulary this client understands are read-only.
  bool get isReadable => version <= 4;
}

/// `session/state` value.
class DshSessionState {
  const DshSessionState({
    required this.cursor,
    required this.active,
    required this.running,
    required this.queue,
    required this.pendingInput,
    this.raw = const {},
  });

  factory DshSessionState.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshSessionState(
      cursor: jsonInt(map['cursor']) ?? 0,
      active: map['active'] == true,
      running: map['running'] == true,
      queue: jsonList(
        map['queue'],
      ).map(DshQueuedItem.fromJson).toList(growable: false),
      pendingInput: jsonStringList(map['pendingInput']),
      raw: map,
    );
  }

  final int cursor;
  final bool active;
  final bool running;
  final List<DshQueuedItem> queue;
  final List<String> pendingInput;
  final Map<String, Object?> raw;

  bool get needsInput => pendingInput.isNotEmpty;
}

/// One inbox item returned by `session/state.queue`.
class DshQueuedItem {
  const DshQueuedItem({
    required this.id,
    required this.placement,
    this.rpcId,
    this.parts = const [],
  });

  factory DshQueuedItem.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshQueuedItem(
      id: jsonString(map['id']) ?? '',
      placement: jsonString(map['placement']) ?? 'queued',
      rpcId: jsonString(map['rpcId']),
      parts: DshPart.listFromJson(map['content']),
    );
  }

  final String id;

  /// `queued`, `steering`, or `context`.
  final String placement;
  final String? rpcId;
  final List<DshPart> parts;

  String get text => parts.whereType<DshTextPart>().map((p) => p.text).join();
}

/// Projection values at [asOfSeq]: title, token usage, model selection,
/// permissions, inbox, image limits, user questions, …
///
/// Values are partial by design (absent key = unknown capability). Typed
/// getters cover what the chat surface needs; [values] stays available for
/// forward-compatible and plugin keys.
/// `contextPressure` projection: the Host-computed token pressure for the ring.
///
/// Sample: `{pressureTokens: 8930, projectedTokens: 8943, contextWindow: 1048576}`.
/// All three are nullable so an older/partial Host does not break the fold; the
/// ring must render only when [contextWindow] is a positive number.
class DshContextPressure {
  const DshContextPressure({
    this.pressureTokens,
    this.projectedTokens,
    this.contextWindow,
  });

  factory DshContextPressure.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshContextPressure(
      pressureTokens: jsonInt(map['pressureTokens']),
      projectedTokens: jsonInt(map['projectedTokens']),
      contextWindow: jsonInt(map['contextWindow']),
    );
  }

  static const empty = DshContextPressure();

  final int? pressureTokens;

  /// Post-turn projection (the meter's hint), not the used value.
  final int? projectedTokens;
  final int? contextWindow;

  bool get isEmpty =>
      pressureTokens == null &&
      projectedTokens == null &&
      contextWindow == null;

  /// Fraction of the context window in use, or null when the Host did not
  /// provide a usable window. Never guessed.
  double? get ratio {
    final used = pressureTokens;
    final window = contextWindow;
    if (used == null || window == null || window <= 0) return null;
    return used / window;
  }
}

class DshSessionProjections {
  const DshSessionProjections({required this.asOfSeq, required this.values});

  factory DshSessionProjections.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshSessionProjections(
      asOfSeq: jsonInt(map['asOfSeq']) ?? 0,
      values: jsonMap(map['values']),
    );
  }

  static const empty = DshSessionProjections(asOfSeq: -1, values: {});

  final int asOfSeq;
  final Map<String, Object?> values;

  Object? operator [](String key) => values[key];

  String? get title => jsonString(values['title']);

  String? get permissionsCurrent {
    final permissions = jsonMap(values['permissions']);
    return jsonString(permissions['currentValue']);
  }

  DshModelSelection? get modelSelectionNext {
    final selection = jsonMap(values['modelSelection']);
    final next = jsonMap(selection['next']);
    return next.isEmpty ? null : DshModelSelection.fromJson(next);
  }

  DshModelSelection? get modelSelectionLastUsed {
    final selection = jsonMap(values['modelSelection']);
    final lastUsed = jsonMap(selection['lastUsed']);
    return lastUsed.isEmpty ? null : DshModelSelection.fromJson(lastUsed);
  }

  DshSessionUsage? get usage {
    final value = values['tokenUsage'];
    return value == null ? null : DshSessionUsage.fromJson(value);
  }

  /// `contextPressure` projection; null when the Host did not send it.
  DshContextPressure? get contextPressure {
    final value = values['contextPressure'];
    if (value == null) return null;
    final pressure = DshContextPressure.fromJson(value);
    return pressure.isEmpty ? null : pressure;
  }

  DshImageLimits get imageLimits =>
      DshImageLimits.fromJson(values['imageLimits']);

  String? get agentPreset => jsonString(values['agentPreset']);

  String? get workingDirectory => jsonString(values['workingDirectory']);

  Map<String, Object?> get inbox => jsonMap(values['inbox']);

  /// Applies one `session/control` projection frame.
  DshSessionProjections withChanges(
    int seq,
    Iterable<MapEntry<String, Object?>> changes,
  ) {
    final next = Map<String, Object?>.of(values);
    for (final change in changes) {
      next[change.key] = change.value;
    }
    return DshSessionProjections(asOfSeq: seq, values: next);
  }
}

/// Composer image budget from the `imageLimits` projection.
class DshImageLimits {
  const DshImageLimits({
    this.maxImageBytes,
    this.maxImagesPerMessage,
    this.maxMessageImageBytes,
    this.maxImagePixels,
    this.maxImageDimension,
    this.mediaTypes = const [
      'image/png',
      'image/jpeg',
      'image/webp',
      'image/gif',
    ],
  });

  factory DshImageLimits.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshImageLimits(
      maxImageBytes: jsonInt(map['maxImageBytes']),
      maxImagesPerMessage: jsonInt(map['maxImagesPerMessage']),
      maxMessageImageBytes: jsonInt(map['maxMessageImageBytes']),
      maxImagePixels: jsonInt(map['maxImagePixels']),
      maxImageDimension: jsonInt(map['maxImageDimension']),
      mediaTypes: jsonStringList(map['mediaTypes']).isEmpty
          ? const ['image/png', 'image/jpeg', 'image/webp', 'image/gif']
          : jsonStringList(map['mediaTypes']),
    );
  }

  final int? maxImageBytes;
  final int? maxImagesPerMessage;
  final int? maxMessageImageBytes;
  final int? maxImagePixels;
  final int? maxImageDimension;
  final List<String> mediaTypes;
}

/// One page of older history (`session/page` / `session/events`).
class DshHistoryPage {
  const DshHistoryPage({
    required this.records,
    required this.hasMore,
    this.cursor,
  });

  factory DshHistoryPage.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshHistoryPage(
      records: jsonList(map['records']).map(jsonMap).toList(growable: false),
      hasMore: map['hasMore'] == true,
      cursor: jsonInt(map['cursor']),
    );
  }

  final List<Map<String, Object?>> records;
  final bool hasMore;
  final int? cursor;
}

/// `session/attachment` value: one prompt image as base64.
class DshSessionAttachment {
  const DshSessionAttachment({
    required this.attachment,
    required this.base64Data,
  });

  factory DshSessionAttachment.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshSessionAttachment(
      attachment: DshImageAttachment.fromJson(map['attachment']),
      base64Data: jsonString(map['data']) ?? '',
    );
  }

  final DshImageAttachment attachment;
  final String base64Data;
}

/// Receipt returned by the upload route; pass [receiptId] as a `file` prompt
/// part ([image] for staged images).
class DshUploadReceipt {
  const DshUploadReceipt({required this.receiptId, this.image, this.file});

  factory DshUploadReceipt.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshUploadReceipt(
      receiptId: jsonString(map['receiptId']) ?? '',
      image: map['image'] == null
          ? null
          : DshImageAttachment.fromJson(map['image']),
      file: map['file'] == null
          ? null
          : DshFileAttachment.fromJson(map['file']),
    );
  }

  final String receiptId;
  final DshImageAttachment? image;
  final DshFileAttachment? file;
}

// =============================================================================
// Model catalog and providers
// =============================================================================

/// One model choice as sent to `session/selectModel`.
class DshModelSelection {
  const DshModelSelection({
    required this.provider,
    required this.model,
    this.reasoningEffort,
  });

  factory DshModelSelection.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshModelSelection(
      provider: jsonString(map['provider']) ?? '',
      model: jsonString(map['model']) ?? '',
      reasoningEffort: jsonString(map['reasoningEffort']),
    );
  }

  final String provider;
  final String model;
  final String? reasoningEffort;

  Map<String, Object?> toJson() => {
    'provider': provider,
    'model': model,
    if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
  };

  @override
  bool operator ==(Object other) =>
      other is DshModelSelection &&
      other.provider == provider &&
      other.model == model &&
      other.reasoningEffort == reasoningEffort;

  @override
  int get hashCode => Object.hash(provider, model, reasoningEffort);

  @override
  String toString() =>
      '$provider/$model${reasoningEffort == null ? '' : ':$reasoningEffort'}';
}

class DshReasoningEffort {
  const DshReasoningEffort({
    required this.id,
    required this.name,
    this.description,
  });

  factory DshReasoningEffort.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshReasoningEffort(
      id: jsonString(map['id']) ?? '',
      name: jsonString(map['name']) ?? jsonString(map['id']) ?? '',
      description: jsonString(map['description']),
    );
  }

  final String id;
  final String name;
  final String? description;
}

class DshReasoningInfo {
  const DshReasoningInfo({required this.efforts, this.defaultEffort});

  factory DshReasoningInfo.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshReasoningInfo(
      efforts: jsonList(
        map['efforts'],
      ).map(DshReasoningEffort.fromJson).toList(growable: false),
      defaultEffort: jsonString(map['defaultEffort']),
    );
  }

  final List<DshReasoningEffort> efforts;
  final String? defaultEffort;

  bool get isEmpty => efforts.isEmpty;
}

class DshModelInfo {
  const DshModelInfo({
    required this.id,
    required this.name,
    this.description,
    this.reasoning,
    this.badge,
  });

  factory DshModelInfo.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshModelInfo(
      id: jsonString(map['id']) ?? '',
      name: jsonString(map['name']) ?? jsonString(map['id']) ?? '',
      description: jsonString(map['description']),
      reasoning: map['reasoning'] == null
          ? null
          : DshReasoningInfo.fromJson(map['reasoning']),
      badge: map['badge'],
    );
  }

  final String id;
  final String name;
  final String? description;
  final DshReasoningInfo? reasoning;

  /// Provider-authored display badge (opaque; render only if recognisable).
  final Object? badge;
}

class DshProviderGroup {
  const DshProviderGroup({
    required this.id,
    required this.name,
    required this.models,
  });

  factory DshProviderGroup.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshProviderGroup(
      id: jsonString(map['id']) ?? '',
      name: jsonString(map['name']) ?? jsonString(map['id']) ?? '',
      models: jsonList(
        map['models'],
      ).map(DshModelInfo.fromJson).toList(growable: false),
    );
  }

  final String id;
  final String name;
  final List<DshModelInfo> models;

  DshModelInfo? modelById(String modelId) {
    for (final model in models) {
      if (model.id == modelId) return model;
    }
    return null;
  }
}

/// A provider whose model lookup failed; render it disabled, not as an error.
class DshModelCatalogFailure {
  const DshModelCatalogFailure({
    required this.id,
    required this.name,
    this.message,
  });

  factory DshModelCatalogFailure.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshModelCatalogFailure(
      id: jsonString(map['id']) ?? '',
      name: jsonString(map['name']) ?? jsonString(map['id']) ?? '',
      message: jsonString(map['message']),
    );
  }

  final String id;
  final String name;
  final String? message;
}

/// `session/modelCatalog` value: the remote's complete model truth.
class DshModelCatalog {
  const DshModelCatalog({
    required this.groups,
    this.defaultSelection,
    this.routableProviders = const [],
    this.failures = const [],
  });

  factory DshModelCatalog.fromJson(Object? json) {
    final map = jsonMap(json);
    final defaultSelection = jsonMap(map['default']);
    return DshModelCatalog(
      defaultSelection: defaultSelection.isEmpty
          ? null
          : DshModelSelection.fromJson(defaultSelection),
      routableProviders: jsonStringList(map['routableProviders']),
      groups: jsonList(
        map['groups'],
      ).map(DshProviderGroup.fromJson).toList(growable: false),
      failures: jsonList(
        map['failures'],
      ).map(DshModelCatalogFailure.fromJson).toList(growable: false),
    );
  }

  static const empty = DshModelCatalog(groups: []);

  final DshModelSelection? defaultSelection;
  final List<String> routableProviders;
  final List<DshProviderGroup> groups;
  final List<DshModelCatalogFailure> failures;

  /// Finds a model across all groups.
  DshModelInfo? model(String provider, String model) {
    for (final group in groups) {
      if (group.id != provider) continue;
      return group.modelById(model);
    }
    return null;
  }
}

/// Static provider route roster entry (`llm/listProviders`).
class DshProviderInfo {
  const DshProviderInfo({required this.id, required this.name});

  factory DshProviderInfo.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshProviderInfo(
      id: jsonString(map['id']) ?? '',
      name: jsonString(map['name']) ?? jsonString(map['id']) ?? '',
    );
  }

  final String id;
  final String name;
}

/// One configurable provider route (`llm/listConfigurableProviders`).
class DshConfigurableProvider {
  const DshConfigurableProvider({
    required this.provider,
    required this.displayName,
    required this.settingsNs,
    required this.settingsPath,
    this.declared,
    this.defaultBaseURL,
    this.baseURLEnv = const [],
    this.nativeAuthEnv = const [],
    this.nativeAuthOauth = false,
    this.raw = const {},
  });

  factory DshConfigurableProvider.fromJson(Object? json) {
    final map = jsonMap(json);
    final nativeAuth = jsonMap(map['nativeAuth']);
    return DshConfigurableProvider(
      provider: jsonString(map['provider']) ?? '',
      displayName:
          jsonString(map['displayName']) ?? jsonString(map['provider']) ?? '',
      settingsNs: jsonString(map['settingsNs']) ?? '',
      settingsPath: jsonStringList(map['settingsPath']),
      declared: jsonBool(map['declared']),
      defaultBaseURL: jsonString(map['defaultBaseURL']),
      baseURLEnv: jsonStringList(map['baseURLEnv']),
      nativeAuthEnv: jsonStringList(nativeAuth['env']),
      nativeAuthOauth: nativeAuth['oauth'] == true,
      raw: map,
    );
  }

  final String provider;
  final String displayName;

  /// Profile namespace that stores this route (`llm-deepseek`, `llm-pi-ai`).
  final String settingsNs;

  /// Path inside the namespace (`[]`, `['providers','openai']`).
  final List<String> settingsPath;

  /// True when configuration declared the route (hand-added gateway).
  final bool? declared;
  final String? defaultBaseURL;
  final List<String> baseURLEnv;
  final List<String> nativeAuthEnv;
  final bool nativeAuthOauth;
  final Map<String, Object?> raw;

  /// Credential reference the official UI derives for this route.
  String get derivedKeyRef {
    final name = provider.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]+'), '_');
    return '${name}_API_KEY';
  }
}

/// `llm/discoverModels` draft route.
class DshModelDiscoveryRequest {
  const DshModelDiscoveryRequest({
    this.provider,
    this.baseURL,
    this.api,
    this.apiKey,
  });

  final String? provider;
  final String? baseURL;
  final String? api;
  final String? apiKey;

  Map<String, Object?> toJson() => {
    if (provider != null) 'provider': provider,
    if (baseURL != null) 'baseURL': baseURL,
    if (api != null) 'api': api,
    if (apiKey != null) 'apiKey': apiKey,
  };
}

/// One model id offered by a draft route.
class DshDiscoveredModel {
  const DshDiscoveredModel({
    required this.id,
    this.name,
    this.contextWindow,
    this.maxTokens,
    this.inputModalities = const [],
  });

  factory DshDiscoveredModel.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshDiscoveredModel(
      id: jsonString(map['id']) ?? '',
      name: jsonString(map['name']),
      contextWindow: jsonInt(map['contextWindow']),
      maxTokens: jsonInt(map['maxTokens']),
      inputModalities: jsonStringList(map['inputModalities']),
    );
  }

  final String id;
  final String? name;
  final int? contextWindow;
  final int? maxTokens;
  final List<String> inputModalities;
}

// =============================================================================
// Permissions, commands, skills
// =============================================================================

/// Closed approval outcome vocabulary recorded in `approval/decided` and
/// returned by the approval waterfall.
enum DshApprovalOutcome {
  allowedOnce('allowed-once'),
  rejected('rejected'),
  cancelled('cancelled'),
  unavailable('unavailable'),
  unknown('unknown');

  const DshApprovalOutcome(this.wire);
  final String wire;

  static DshApprovalOutcome parse(Object? value) => switch (value) {
    'allowed-once' => allowedOnce,
    'rejected' => rejected,
    'cancelled' => cancelled,
    'unavailable' => unavailable,
    _ => unknown,
  };
}

class DshPermissionPreset {
  const DshPermissionPreset({
    required this.value,
    required this.name,
    this.description,
  });

  factory DshPermissionPreset.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshPermissionPreset(
      value: jsonString(map['value']) ?? jsonString(map['preset']) ?? '',
      name:
          jsonString(map['name']) ??
          jsonString(map['label']) ??
          jsonString(map['value']) ??
          '',
      description: jsonString(map['description']),
    );
  }

  final String value;
  final String name;
  final String? description;
}

/// `permissionPresets/catalog` value. The session's *current* preset is the
/// `permissions` projection, not this catalog.
class DshPermissionPresetCatalog {
  const DshPermissionPresetCatalog({
    required this.options,
    required this.defaultOptions,
    required this.defaultPreset,
  });

  factory DshPermissionPresetCatalog.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshPermissionPresetCatalog(
      options: jsonList(
        map['options'],
      ).map(DshPermissionPreset.fromJson).toList(growable: false),
      defaultOptions: jsonList(
        map['defaultOptions'],
      ).map(DshPermissionPreset.fromJson).toList(growable: false),
      defaultPreset: jsonString(map['defaultPreset']),
    );
  }

  final List<DshPermissionPreset> options;
  final List<DshPermissionPreset> defaultOptions;
  final String? defaultPreset;

  DshPermissionPreset? option(String value) {
    for (final option in options) {
      if (option.value == value) return option;
    }
    return null;
  }
}

class DshCommandDescriptor {
  const DshCommandDescriptor({
    required this.name,
    required this.description,
    this.definitionId,
    this.inputHint,
    this.inputAttachments = false,
  });

  factory DshCommandDescriptor.fromJson(Object? json) {
    final map = jsonMap(json);
    final input = jsonMap(map['input']);
    return DshCommandDescriptor(
      name: jsonString(map['name']) ?? '',
      description: jsonString(map['description']) ?? '',
      definitionId: jsonString(map['definitionId']),
      inputHint: jsonString(input['hint']),
      inputAttachments: input['attachments'] == true,
    );
  }

  /// Lowercase command name without the leading slash.
  final String name;
  final String description;
  final String? definitionId;
  final String? inputHint;
  final bool inputAttachments;
}

/// In-band outcome of `commands/execute`; not a RemoteError.
class DshCommandResult {
  const DshCommandResult({
    required this.success,
    this.text,
    this.sourceEventSeq,
  });

  factory DshCommandResult.fromJson(Object? json) {
    final map = jsonMap(json);
    final kind = jsonString(map['kind']);
    return DshCommandResult(
      success: kind == 'success',
      text: jsonString(map['text']),
      sourceEventSeq: jsonInt(map['sourceEventSeq']),
    );
  }

  final bool success;
  final String? text;
  final int? sourceEventSeq;
}

class DshCommandExecution {
  const DshCommandExecution({this.commandId, required this.result});

  factory DshCommandExecution.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshCommandExecution(
      commandId: jsonString(map['commandId']),
      result: DshCommandResult.fromJson(map['result']),
    );
  }

  final String? commandId;
  final DshCommandResult result;
}

/// One user-invocable skill (`skills/list`).
class DshSkill {
  const DshSkill({
    required this.name,
    required this.description,
    this.path,
    this.whenToUse,
    this.modelInvocable = false,
  });

  factory DshSkill.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshSkill(
      name: jsonString(map['name']) ?? '',
      description: jsonString(map['description']) ?? '',
      path: jsonString(map['path']),
      whenToUse: jsonString(map['whenToUse']),
      modelInvocable: map['modelInvocable'] == true,
    );
  }

  final String name;
  final String description;
  final String? path;
  final String? whenToUse;
  final bool modelInvocable;
}

// =============================================================================
// Workspaces
// =============================================================================

class DshWorkspace {
  const DshWorkspace({
    required this.workspaceId,
    required this.path,
    required this.title,
    required this.sessionIds,
    this.createdAt,
    this.updatedAt,
    this.raw = const {},
  });

  factory DshWorkspace.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshWorkspace(
      workspaceId: jsonString(map['workspaceId']) ?? '',
      path: jsonString(map['path']) ?? '',
      title: jsonString(map['title']) ?? '',
      sessionIds: jsonStringList(map['sessionIds']),
      createdAt: jsonIsoDateTime(map['createdAt']),
      updatedAt: jsonIsoDateTime(map['updatedAt']),
      raw: map,
    );
  }

  final String workspaceId;
  final String path;
  final String title;

  /// Sessions accounted to this workspace, in manual order.
  final List<String> sessionIds;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final Map<String, Object?> raw;
}

/// Complete `workspace/follow` state: every workspace plus the archive and pin
/// sets (each replaces the local set when received).
class DshWorkspaceBaseline {
  const DshWorkspaceBaseline({
    required this.items,
    this.archivedSessionIds = const [],
    this.pinnedSessionIds = const [],
  });

  factory DshWorkspaceBaseline.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshWorkspaceBaseline(
      items: jsonList(
        map['items'],
      ).map(DshWorkspace.fromJson).toList(growable: false),
      archivedSessionIds: jsonStringList(map['archivedSessionIds']),
      pinnedSessionIds: jsonStringList(map['pinnedSessionIds']),
    );
  }

  static const empty = DshWorkspaceBaseline(items: []);

  final List<DshWorkspace> items;
  final List<String> archivedSessionIds;
  final List<String> pinnedSessionIds;

  DshWorkspace? workspaceOf(String workspaceId) {
    for (final item in items) {
      if (item.workspaceId == workspaceId) return item;
    }
    return null;
  }
}

/// One workspace mutation result payload (`{workspace}`).
class DshWorkspaceValue {
  const DshWorkspaceValue(this.workspace);
  final DshWorkspace workspace;
}

/// `workspace/create` result.
class DshWorkspaceCreated {
  const DshWorkspaceCreated({required this.workspace, this.created = false});

  factory DshWorkspaceCreated.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshWorkspaceCreated(
      workspace: DshWorkspace.fromJson(map['workspace']),
      created: map['created'] == true,
    );
  }

  final DshWorkspace workspace;
  final bool created;
}

// =============================================================================
// Plugins
// =============================================================================

/// A plugin display string: a plain literal, or a locale map (`{en, zh, …}`).
class DshLocalizedText {
  const DshLocalizedText(this.values);

  factory DshLocalizedText.fromJson(Object? json) {
    if (json is String) return DshLocalizedText({'en': json});
    final values = <String, String>{};
    jsonMap(json).forEach((key, value) {
      if (value is String) values[key] = value;
    });
    return DshLocalizedText(values);
  }

  final Map<String, String> values;

  bool get isEmpty => values.isEmpty;

  /// Resolves [locale] (`zh_CN` and `zh-CN` both hit `zh`), then `en`, then the
  /// first available translation.
  String? resolve(String locale) {
    if (values.isEmpty) return null;
    final normalized = locale.replaceAll('_', '-');
    final exact = values[locale] ?? values[normalized];
    if (exact != null) return exact;
    final language = normalized.split('-').first;
    final languageMatch = values[language];
    if (languageMatch != null) return languageMatch;
    return values['en'] ?? values.values.first;
  }
}

/// One plugin Loader entry (`pluginInventory/list`).
class DshPluginInventoryEntry {
  const DshPluginInventoryEntry({
    required this.entryId,
    required this.moduleName,
    required this.enabled,
    this.fiberPhase,
    this.title,
    this.description,
    this.icon,
    this.diagnostic,
    this.raw = const {},
  });

  factory DshPluginInventoryEntry.fromJson(Object? json) {
    final map = jsonMap(json);
    final meta = jsonMap(map['meta']);
    return DshPluginInventoryEntry(
      entryId: jsonString(map['entryId']) ?? '',
      moduleName: jsonString(map['moduleName']) ?? '',
      enabled: map['enabled'] == true,
      fiberPhase: jsonString(map['fiberPhase']),
      title: meta['title'] == null
          ? null
          : DshLocalizedText.fromJson(meta['title']),
      description: meta['description'] == null
          ? null
          : DshLocalizedText.fromJson(meta['description']),
      icon: jsonString(meta['icon']),
      diagnostic: jsonString(map['diagnostic']),
      raw: map,
    );
  }

  final String entryId;
  final String moduleName;
  final bool enabled;

  /// `pending`, `loading`, `active`, `failed`, `unloading`, or null.
  final String? fiberPhase;
  final DshLocalizedText? title;
  final DshLocalizedText? description;

  /// Base64 data URL (render as an image, never as markup).
  final String? icon;
  final String? diagnostic;
  final Map<String, Object?> raw;

  String get displayName => title?.resolve('en') ?? moduleName;
}

/// One plugin row an agent preset composition names.
class DshPresetPluginRow {
  const DshPresetPluginRow({
    required this.moduleName,
    this.entryId,
    this.enabled = true,
    this.conditional = false,
    this.condition,
    this.fiberPhase,
    this.title,
  });

  factory DshPresetPluginRow.fromJson(Object? json) {
    final map = jsonMap(json);
    final meta = jsonMap(map['meta']);
    return DshPresetPluginRow(
      moduleName: jsonString(map['moduleName']) ?? '',
      entryId: jsonString(map['entryId']),
      enabled: map['enabled'] != false,
      conditional: map['enabled'] == 'conditional',
      condition: jsonString(map['condition']),
      fiberPhase: jsonString(map['fiberPhase']),
      title: meta['title'] == null
          ? null
          : DshLocalizedText.fromJson(meta['title']),
    );
  }

  final String moduleName;
  final String? entryId;
  final bool enabled;

  /// The row's `!!js` disabled expression needs a Loader context to evaluate.
  final bool conditional;
  final String? condition;
  final String? fiberPhase;
  final DshLocalizedText? title;
}

/// One agent preset's flattened plugin composition.
class DshAgentPresetPluginGroup {
  const DshAgentPresetPluginGroup({
    required this.id,
    required this.rows,
    this.name,
    this.isDefault = false,
    this.broken,
  });

  factory DshAgentPresetPluginGroup.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshAgentPresetPluginGroup(
      id: jsonString(map['id']) ?? '',
      name: jsonString(map['name']),
      isDefault: map['isDefault'] == true,
      broken: jsonString(map['broken']),
      rows: jsonList(
        map['rows'],
      ).map(DshPresetPluginRow.fromJson).toList(growable: false),
    );
  }

  final String id;
  final String? name;
  final bool isDefault;

  /// Why the composition cannot be read (rows are empty then).
  final String? broken;
  final List<DshPresetPluginRow> rows;
}

/// `pluginInventory/list` value.
class DshPluginInventory {
  const DshPluginInventory({
    required this.entries,
    this.managementAvailable,
    this.agentPresets = const [],
  });

  factory DshPluginInventory.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshPluginInventory(
      entries: jsonList(
        map['entries'],
      ).map(DshPluginInventoryEntry.fromJson).toList(growable: false),
      managementAvailable: jsonBool(map['managementAvailable']),
      agentPresets: jsonList(
        map['agentPresets'],
      ).map(DshAgentPresetPluginGroup.fromJson).toList(growable: false),
    );
  }

  static const empty = DshPluginInventory(entries: []);

  final List<DshPluginInventoryEntry> entries;
  final bool? managementAvailable;
  final List<DshAgentPresetPluginGroup> agentPresets;
}

/// One shipped/installed bundle row (`pluginManager/listBundles`).
class DshPluginBundleInfo {
  const DshPluginBundleInfo({
    required this.name,
    required this.official,
    required this.availability,
    required this.enabled,
    required this.installed,
    this.version,
    this.description,
    this.title,
    this.source,
    this.listedByDefault,
    this.raw = const {},
  });

  factory DshPluginBundleInfo.fromJson(Object? json) {
    final map = jsonMap(json);
    final meta = jsonMap(map['meta']);
    return DshPluginBundleInfo(
      name: jsonString(map['name']) ?? '',
      official: map['official'] == true,
      availability: jsonString(map['availability']) ?? 'missing',
      enabled: map['enabled'] == true,
      installed: map['installed'] == true,
      version: jsonString(map['version']),
      description: jsonString(map['description']),
      title: meta['title'] == null
          ? null
          : DshLocalizedText.fromJson(meta['title']),
      source: jsonString(map['source']),
      listedByDefault: jsonBool(map['listedByDefault']),
      raw: map,
    );
  }

  final String name;
  final bool official;

  /// `installation`, `profile`, or `missing`.
  final String availability;
  final bool enabled;
  final bool installed;
  final String? version;
  final String? description;
  final DshLocalizedText? title;
  final String? source;
  final bool? listedByDefault;
  final Map<String, Object?> raw;

  String get displayName => title?.resolve('en') ?? name;
}

/// One manageable plugin row (`pluginManager/listPlugins`): inventory entry
/// plus management eligibility.
class DshPluginInfo {
  const DshPluginInfo({required this.entry, this.patchId, this.readOnlyReason});

  factory DshPluginInfo.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshPluginInfo(
      entry: DshPluginInventoryEntry.fromJson(map),
      patchId: jsonString(map['patchId']),
      readOnlyReason: jsonString(map['readOnlyReason']),
    );
  }

  final DshPluginInventoryEntry entry;

  /// Present when the plugin is editable through a profile patch.
  final String? patchId;
  final String? readOnlyReason;

  bool get manageable => readOnlyReason == null;
}

/// Result of a plugin management mutation.
class DshPluginChangeResult {
  const DshPluginChangeResult({
    required this.changed,
    required this.application,
    this.target,
    this.stage,
    this.enabled,
    this.errorMessage,
    this.restartReason,
    this.raw = const {},
  });

  factory DshPluginChangeResult.fromJson(Object? json) {
    final map = jsonMap(json);
    final error = jsonMap(map['error']);
    return DshPluginChangeResult(
      changed: map['changed'] == true,
      application: jsonString(map['application']) ?? 'failed',
      target: jsonString(map['target']),
      stage: jsonString(map['stage']),
      enabled: jsonBool(map['enabled']),
      errorMessage: jsonString(error['message']) ?? jsonString(error['code']),
      restartReason: jsonString(map['restartReason']),
      raw: map,
    );
  }

  final bool changed;

  /// `applied`, `restart-required`, `overridden`, `failed`, or `cancelled`.
  final String application;
  final String? target;
  final String? stage;
  final bool? enabled;
  final String? errorMessage;
  final String? restartReason;
  final Map<String, Object?> raw;

  bool get applied =>
      application == 'applied' || application == 'restart-required';
}

// =============================================================================
// Settings, credentials, account
// =============================================================================

/// One schema-declared secret slot: configured state only, never the value.
class DshSettingsSecret {
  const DshSettingsSecret({required this.path, required this.set});

  factory DshSettingsSecret.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshSettingsSecret(
      path: jsonStringList(map['path']),
      set: map['set'] == true,
    );
  }

  final List<String> path;
  final bool set;
}

/// One profile namespace view from `settings/describe`/writes.
class DshSettingsNamespace {
  const DshSettingsNamespace({
    required this.ns,
    required this.revision,
    required this.value,
    required this.secrets,
    this.schema,
    this.base,
    this.user,
    this.applies = 'live',
    this.autoGenerate = false,
  });

  factory DshSettingsNamespace.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshSettingsNamespace(
      ns: jsonString(map['ns']) ?? '',
      revision: jsonInt(map['revision']) ?? 0,
      schema: map['schema'],
      value: map['value'],
      base: map['base'],
      user: map['user'],
      applies: jsonString(map['applies']) ?? 'live',
      autoGenerate: map['autoGenerate'] == true,
      secrets: jsonList(
        map['secrets'],
      ).map(DshSettingsSecret.fromJson).toList(growable: false),
    );
  }

  final String ns;

  /// CAS token: send it as `expectedRevision` on the next write.
  final int revision;

  /// Serialized schemastery schema envelope (`schema.toJSON()`).
  final Object? schema;

  /// Redacted resolved value (defaults → composition base → user layer).
  final Object? value;

  /// Redacted composition base layer.
  final Object? base;

  /// Raw user layer; a field's presence marks it user-overridden.
  final Object? user;
  final String applies;
  final bool autoGenerate;
  final List<DshSettingsSecret> secrets;
}

/// `settings/describe` value.
class DshSettingsDescription {
  const DshSettingsDescription({
    required this.writable,
    required this.namespaces,
    this.hasDocument = false,
  });

  factory DshSettingsDescription.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshSettingsDescription(
      writable: map['writable'] == true,
      hasDocument: map['hasDocument'] == true,
      namespaces: jsonList(
        map['namespaces'],
      ).map(DshSettingsNamespace.fromJson).toList(growable: false),
    );
  }

  static const empty = DshSettingsDescription(writable: false, namespaces: []);

  final bool writable;
  final bool hasDocument;
  final List<DshSettingsNamespace> namespaces;

  DshSettingsNamespace? namespace(String ns) {
    for (final item in namespaces) {
      if (item.ns == ns) return item;
    }
    return null;
  }
}

/// One path-addressed settings write (`settings/mutate` ops).
sealed class DshSettingsPathOp {
  const DshSettingsPathOp(this.path);
  final List<String> path;
  Map<String, Object?> toJson();
}

final class DshSettingsSetOp extends DshSettingsPathOp {
  const DshSettingsSetOp(super.path, this.value);
  final Object? value;

  @override
  Map<String, Object?> toJson() => {'op': 'set', 'path': path, 'value': value};
}

final class DshSettingsUnsetOp extends DshSettingsPathOp {
  const DshSettingsUnsetOp(super.path);

  @override
  Map<String, Object?> toJson() => {'op': 'unset', 'path': path};
}

/// One credential reference's state (`credentials/describe`).
class DshCredentialInfo {
  const DshCredentialInfo({
    required this.configured,
    this.source,
    this.writable = false,
    this.raw = const {},
  });

  factory DshCredentialInfo.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshCredentialInfo(
      configured: map['configured'] == true,
      source: jsonString(map['source']),
      writable: map['writable'] == true,
      raw: map,
    );
  }

  final bool configured;
  final String? source;
  final bool writable;
  final Map<String, Object?> raw;
}

class DshAccountLinks {
  const DshAccountLinks({this.usageUrl, this.topUpUrl});

  factory DshAccountLinks.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshAccountLinks(
      usageUrl: jsonString(map['usageUrl']),
      topUpUrl: jsonString(map['topUpUrl']),
    );
  }

  final String? usageUrl;
  final String? topUpUrl;
}

/// `account/getState` value.
class DshAccountState {
  const DshAccountState({
    required this.status,
    required this.links,
    this.attempt,
  });

  factory DshAccountState.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshAccountState(
      status: jsonString(map['status']) ?? 'signed-out',
      links: DshAccountLinks.fromJson(map['links']),
      attempt: map['attempt'],
    );
  }

  final String status;
  final DshAccountLinks links;
  final Object? attempt;

  bool get signedOut => status == 'signed-out';
}

/// One `workspaceFiles/stat` answer.
///
/// `absolutePath` is what `GET /api/file?path=` expects; `version` is the
/// cache-busting token the versioned preview URL carries. [bytes] is present
/// when the Host included the size.
class DshFileStat {
  const DshFileStat({
    required this.absolutePath,
    this.path,
    this.version,
    this.bytes,
    this.mediaType,
    this.raw = const {},
  });

  factory DshFileStat.fromJson(Object? json, {String? path}) {
    final map = jsonMap(json);
    return DshFileStat(
      absolutePath: jsonString(map['absolutePath']) ?? '',
      path: path,
      version: jsonString(map['version']),
      bytes: jsonInt(map['bytes']),
      mediaType: jsonString(map['mediaType']),
      raw: map,
    );
  }

  /// Absolute Host path (`GET /api/file?path=` consumes it).
  final String absolutePath;

  /// The workspace-relative path that was requested (echoed by the client).
  final String? path;

  /// Version token for `GET /api/file?path=…&v=…` (cacheable preview URL).
  final String? version;
  final int? bytes;
  final String? mediaType;
  final Map<String, Object?> raw;

  bool get hasAbsolutePath => absolutePath.isNotEmpty;
}

/// One `agentPresets/list` row (`{presets:[{id,order,isDefault}]}`).
class DshAgentPresetSummary {
  const DshAgentPresetSummary({
    required this.id,
    required this.order,
    required this.isDefault,
    this.name,
    this.description,
    this.broken,
    this.raw = const {},
  });

  factory DshAgentPresetSummary.fromJson(Object? json) {
    final map = jsonMap(json);
    return DshAgentPresetSummary(
      id: jsonString(map['id']) ?? '',
      order: jsonInt(map['order']) ?? 0,
      isDefault: map['isDefault'] == true,
      name: jsonString(map['name']),
      description: jsonString(map['description']),
      broken: jsonString(map['broken']),
      raw: map,
    );
  }

  final String id;

  /// Display order supplied by the Host (ascending).
  final int order;
  final bool isDefault;

  /// Display name the preset published; null for the shipped presets, whose
  /// copy the client localizes by [id].
  final String? name;

  /// One sentence on what this preset is for; null when unpublished.
  final String? description;

  /// Why this preset cannot compose a Session; null when it can.
  final String? broken;
  final Map<String, Object?> raw;
}

/// Session-control stream frames (`session/control`).
sealed class DshSessionControlUpdate {
  const DshSessionControlUpdate();
}

final class DshSessionControlBaseline extends DshSessionControlUpdate {
  const DshSessionControlBaseline(this.projections);
  final Map<String, DshSessionProjections> projections;
}

/// One projection key change in a `session/control` frame.
class DshSessionControlChange {
  const DshSessionControlChange({required this.key, required this.value});

  /// Projection key (`title`, `permissions`, `modelSelection`, …).
  final String key;

  /// Complete new value for that key (not a patch).
  final Object? value;
}

final class DshSessionControlProjection extends DshSessionControlUpdate {
  const DshSessionControlProjection({
    required this.sessionId,
    required this.changes,
    required this.seq,
  });

  final String sessionId;

  /// One entry per changed key in this frame.
  final List<DshSessionControlChange> changes;

  /// Committed event `seq` that caused the change.
  final int seq;

  /// Convenience for the common single-key frame.
  String? get key => changes.isEmpty ? null : changes.first.key;

  /// Convenience for the common single-key frame.
  Object? get value => changes.isEmpty ? null : changes.first.value;
}
