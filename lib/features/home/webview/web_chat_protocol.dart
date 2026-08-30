import 'dart:convert';
import 'dart:math';

const int webChatProtocolVersion = 5;
const String webChatAssetVersion = 'web-chat-v20';
const int webChatMaxChunkBytes = 128 * 1024;
const int webChatMaxChunkPayloadBytes = 95 * 1024;

/// Cap for media payloads served over the Web bridge (avatars, images).
const int webChatMediaMaxBytes = 16 * 1024 * 1024;

/// Cap for font payloads: CJK collections can exceed the image cap.
const int webChatFontMaxBytes = 32 * 1024 * 1024;

/// Latest-wins buffer for streaming message patches.
///
/// A WebView controller call can take longer than one model chunk. This keeps
/// at most one bridge batch in flight and retains only the newest pending
/// state for each message while that batch is being delivered.
class WebChatStreamingPatchBuffer {
  final Map<String, Map<String, dynamic>> _pending =
      <String, Map<String, dynamic>>{};
  final Map<String, int> _revisions = <String, int>{};
  bool _inFlight = false;

  bool get hasPending => _pending.isNotEmpty;
  bool get inFlight => _inFlight;

  int enqueue(String messageId, Map<String, dynamic> patch) {
    final revision = (_revisions[messageId] ?? 0) + 1;
    _revisions[messageId] = revision;
    _pending[messageId] = <String, dynamic>{
      ...patch,
      'id': messageId,
      'streamRevision': revision,
    };
    return revision;
  }

  List<Map<String, dynamic>>? takeBatch() {
    if (_inFlight || _pending.isEmpty) return null;
    _inFlight = true;
    final batch = _pending.values
        .map(Map<String, dynamic>.of)
        .toList(growable: false);
    _pending.clear();
    return batch;
  }

  void completeBatch() {
    _inFlight = false;
  }

  void remove(String messageId) {
    _pending.remove(messageId);
  }

  void clear() {
    _pending.clear();
    _revisions.clear();
  }
}

/// Serializes full snapshot delivery until JavaScript acknowledges a committed
/// render. While one snapshot is in flight, only the newest pending snapshot is
/// retained.
class WebChatSnapshotSendQueue {
  Map<String, dynamic>? _inFlight;
  Map<String, dynamic>? _pending;

  bool get hasInFlight => _inFlight != null;
  bool get hasPending => _pending != null;
  Map<String, dynamic>? get inFlight => _inFlight;

  void enqueue(Map<String, dynamic> snapshot) {
    _pending = Map<String, dynamic>.of(snapshot);
  }

  Map<String, dynamic>? takeNext() {
    if (_inFlight != null || _pending == null) return null;
    final next = _pending!;
    _pending = null;
    _inFlight = next;
    return next;
  }

  bool acknowledge({
    required String renderSessionId,
    required String conversationId,
    required int renderRevision,
  }) {
    final current = _inFlight;
    if (current == null ||
        current['renderSessionId'] != renderSessionId ||
        current['conversationId'] != conversationId ||
        current['renderRevision'] != renderRevision) {
      return false;
    }
    _inFlight = null;
    return true;
  }

  void clear() {
    _inFlight = null;
    _pending = null;
  }
}

class WebChatProtocolException implements Exception {
  const WebChatProtocolException(this.message);

  final String message;

  @override
  String toString() => 'WebChatProtocolException: $message';
}

class WebChatActionRequest {
  const WebChatActionRequest({
    required this.requestId,
    required this.renderSessionId,
    required this.conversationId,
    required this.actionEpoch,
    required this.action,
    this.messageId,
    this.payload = const <String, dynamic>{},
  });

  final String requestId;
  final String renderSessionId;
  final String conversationId;
  final int actionEpoch;
  final String action;
  final String? messageId;
  final Map<String, dynamic> payload;

  factory WebChatActionRequest.fromJson(Map<String, dynamic> json) {
    final payload = json['payload'];
    final request = WebChatActionRequest(
      requestId: json['requestId']?.toString() ?? '',
      renderSessionId: json['renderSessionId']?.toString() ?? '',
      conversationId: json['conversationId']?.toString() ?? '',
      actionEpoch: (json['actionEpoch'] as num?)?.toInt() ?? -1,
      action: json['action']?.toString() ?? '',
      messageId: json['messageId']?.toString(),
      payload: payload is Map
          ? payload.map((key, value) => MapEntry(key.toString(), value))
          : const <String, dynamic>{},
    );
    if (request.requestId.isEmpty ||
        request.renderSessionId.isEmpty ||
        request.conversationId.isEmpty ||
        request.action.isEmpty) {
      throw const WebChatProtocolException('malformed action request');
    }
    return request;
  }
}

enum WebChatReasoningKind { single, segment }

class WebChatReasoningTarget {
  const WebChatReasoningTarget({
    required this.kind,
    required this.index,
    required this.expanded,
  });

  final WebChatReasoningKind kind;
  final int index;
  final bool expanded;

  factory WebChatReasoningTarget.fromPayload(Map<String, dynamic> payload) {
    final kind = switch (payload['kind']) {
      'single' => WebChatReasoningKind.single,
      'segment' => WebChatReasoningKind.segment,
      _ => throw const WebChatProtocolException(
        'unsupported reasoning target kind',
      ),
    };
    final rawIndex = payload['index'];
    final rawExpanded = payload['expanded'];
    if (rawIndex is! num ||
        !rawIndex.isFinite ||
        rawIndex != rawIndex.toInt() ||
        rawIndex.toInt() < 0 ||
        (kind == WebChatReasoningKind.single && rawIndex.toInt() != 0) ||
        rawExpanded is! bool) {
      throw const WebChatProtocolException('malformed reasoning target');
    }
    return WebChatReasoningTarget(
      kind: kind,
      index: rawIndex.toInt(),
      expanded: rawExpanded,
    );
  }
}

class WebChatActionGate {
  WebChatActionGate({
    required this.renderSessionId,
    required this.conversationId,
    required this.actionEpoch,
  });

  final String renderSessionId;
  final String conversationId;
  final int actionEpoch;
  final Set<String> _handledRequestIds = <String>{};

  bool accept(WebChatActionRequest request) {
    if (request.renderSessionId != renderSessionId ||
        request.conversationId != conversationId ||
        request.actionEpoch != actionEpoch) {
      return false;
    }
    return _handledRequestIds.add(request.requestId);
  }
}

List<Map<String, dynamic>> chunkWebChatEnvelope({
  required Map<String, dynamic> payload,
  required String transferId,
  int maxChunkBytes = webChatMaxChunkPayloadBytes,
}) {
  if (maxChunkBytes <= 0) {
    throw const WebChatProtocolException('maxChunkBytes must be positive');
  }
  final bytes = utf8.encode(jsonEncode(payload));
  final total = max(1, (bytes.length / maxChunkBytes).ceil());
  return <Map<String, dynamic>>[
    for (var index = 0; index < total; index++)
      <String, dynamic>{
        'type': 'transferChunk',
        'protocolVersion': webChatProtocolVersion,
        'transferId': transferId,
        'index': index,
        'total': total,
        'data': base64Encode(
          bytes.sublist(
            index * maxChunkBytes,
            min(bytes.length, (index + 1) * maxChunkBytes),
          ),
        ),
      },
  ];
}
