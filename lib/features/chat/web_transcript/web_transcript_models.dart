import 'dart:convert';

import '../../../core/models/chat_message.dart';

const int webTranscriptProtocolVersion = 1;

enum WebTranscriptResourceKind { image, attachment, background }

class WebTranscriptResource {
  const WebTranscriptResource({
    required this.id,
    required this.source,
    required this.kind,
    this.fileName,
    this.mimeType,
  });

  final String id;
  final String source;
  final WebTranscriptResourceKind kind;
  final String? fileName;
  final String? mimeType;
}

class WebTranscriptAction {
  const WebTranscriptAction(this.type, this.label, {this.value});

  final String type;
  final String label;
  final String? value;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'label': label,
    'value': value,
  };
}

class WebTranscriptMessage {
  const WebTranscriptMessage({
    required this.source,
    required this.markdown,
    required this.format,
    required this.displayName,
    required this.timestamp,
    required this.timestampIso,
    required this.actions,
    required this.selected,
    required this.spotlight,
  });

  final ChatMessage source;
  final String markdown;
  final String format;
  final String displayName;
  final String timestamp;
  final String timestampIso;
  final List<WebTranscriptAction> actions;
  final bool selected;
  final bool spotlight;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': source.id,
    'role': source.role,
    'markdown': markdown,
    'format': format,
    'displayName': displayName,
    'timestamp': timestamp,
    'timestampIso': timestampIso,
    'actions': actions.map((action) => action.toJson()).toList(),
    'streaming': source.isStreaming,
    'selected': selected,
    'spotlight': spotlight,
  };
}

class WebTranscriptSnapshot {
  const WebTranscriptSnapshot({
    required this.conversationId,
    required this.messages,
    required this.resources,
    required this.hasMoreBefore,
    required this.hasMoreAfter,
  });

  final String conversationId;
  final List<WebTranscriptMessage> messages;
  final Map<String, WebTranscriptResource> resources;
  final bool hasMoreBefore;
  final bool hasMoreAfter;

  Map<String, Object?> toJson() => <String, Object?>{
    'conversationId': conversationId,
    'messages': messages.map((message) => message.toJson()).toList(),
    'hasMoreBefore': hasMoreBefore,
    'hasMoreAfter': hasMoreAfter,
  };
}

class WebTranscriptBridgeEvent {
  const WebTranscriptBridgeEvent({
    required this.version,
    required this.epoch,
    required this.type,
    required this.payload,
    this.commandId,
  });

  final int version;
  final int epoch;
  final String type;
  final Map<String, dynamic> payload;
  final String? commandId;

  static WebTranscriptBridgeEvent parse(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Bridge event must be a JSON object');
    }
    final version = decoded['version'];
    final epoch = decoded['epoch'];
    final type = decoded['type'];
    final payload = decoded['payload'];
    final commandId = decoded['commandId'];
    if (version is! int || epoch is! int || type is! String) {
      throw const FormatException('Bridge event envelope is invalid');
    }
    if (payload is! Map<String, dynamic>) {
      throw const FormatException('Bridge event payload must be an object');
    }
    if (commandId != null && commandId is! String) {
      throw const FormatException('Bridge event commandId must be a string');
    }
    return WebTranscriptBridgeEvent(
      version: version,
      epoch: epoch,
      type: type,
      payload: payload,
      commandId: commandId as String?,
    );
  }
}
