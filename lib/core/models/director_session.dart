import 'dart:convert';

import 'package:uuid/uuid.dart';

/// Hidden director orchestration state for a group chat.
///
/// Not shown in the side-drawer conversation list. [messages] holds the
/// director's private transcript (list of role/content maps).
///
/// copyWith uses the plain `??` pattern; nullable clears via flags.
class DirectorSession {
  static const String statusIdle = 'idle';
  static const String statusDirecting = 'directing';
  static const String statusMemberSpeaking = 'member_speaking';
  static const String statusDone = 'done';
  static const String statusError = 'error';

  final String id;
  final String groupId;
  final String status;

  /// Director hidden chat history (role/content maps).
  final List<Map<String, dynamic>> messages;

  final String? triggerUserMessageId;

  /// Round counters and other ephemeral orchestration state.
  final Map<String, dynamic> state;

  final String? errorText;
  final DateTime createdAt;
  final DateTime updatedAt;

  DirectorSession({
    String? id,
    required this.groupId,
    this.status = statusIdle,
    List<Map<String, dynamic>>? messages,
    this.triggerUserMessageId,
    Map<String, dynamic>? state,
    this.errorText,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : id = id ?? const Uuid().v4(),
       messages = messages ?? <Map<String, dynamic>>[],
       state = state ?? <String, dynamic>{},
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  DirectorSession copyWith({
    String? id,
    String? groupId,
    String? status,
    List<Map<String, dynamic>>? messages,
    String? triggerUserMessageId,
    Map<String, dynamic>? state,
    String? errorText,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool clearTriggerUserMessageId = false,
    bool clearErrorText = false,
  }) {
    return DirectorSession(
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
      status: status ?? this.status,
      messages: messages ?? this.messages,
      triggerUserMessageId: clearTriggerUserMessageId
          ? null
          : (triggerUserMessageId ?? this.triggerUserMessageId),
      state: state ?? this.state,
      errorText: clearErrorText ? null : (errorText ?? this.errorText),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'groupId': groupId,
      'status': status,
      'messages': messages,
      'triggerUserMessageId': triggerUserMessageId,
      'state': state,
      'errorText': errorText,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory DirectorSession.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> parseMessages(Object? raw) {
      if (raw is String && raw.isNotEmpty) {
        try {
          raw = jsonDecode(raw);
        } catch (_) {
          return <Map<String, dynamic>>[];
        }
      }
      if (raw is! List) return <Map<String, dynamic>>[];
      return raw
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    }

    Map<String, dynamic> parseState(Object? raw) {
      if (raw is String && raw.isNotEmpty) {
        try {
          raw = jsonDecode(raw);
        } catch (_) {
          return <String, dynamic>{};
        }
      }
      if (raw is! Map) return <String, dynamic>{};
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }

    return DirectorSession(
      id: json['id'] as String,
      groupId: json['groupId'] as String,
      status: json['status'] as String? ?? statusIdle,
      messages: parseMessages(json['messages'] ?? json['messagesJson']),
      triggerUserMessageId: json['triggerUserMessageId'] as String?,
      state: parseState(json['state'] ?? json['stateJson']),
      errorText: json['errorText'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }
}
