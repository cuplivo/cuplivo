import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'group_chat_settings.dart';

/// Multi-assistant group chat room (parallel to 1:1 [Conversation]).
///
/// Does not use [Conversation] / message.groupId (those are version groups).
///
/// copyWith uses the plain `??` pattern; [summary] / [avatar] clear via flags.
class GroupChat {
  final String id;
  String title;
  String? avatar;
  final DateTime createdAt;
  DateTime updatedAt;
  bool isPinned;
  GroupChatSettings settings;
  String? summary;

  /// In-memory member ids ordered by sortOrder; not a DB column on the group row.
  List<String> memberIds;

  /// In-memory message ids ordered by messageOrder; not a DB column on the group row.
  List<String> messageIds;

  GroupChat({
    String? id,
    required this.title,
    this.avatar,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.isPinned = false,
    GroupChatSettings? settings,
    this.summary,
    List<String>? memberIds,
    List<String>? messageIds,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now(),
       settings = settings ?? GroupChatSettings.defaults,
       memberIds = memberIds ?? [],
       messageIds = messageIds ?? [];

  GroupChat copyWith({
    String? id,
    String? title,
    String? avatar,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isPinned,
    GroupChatSettings? settings,
    String? summary,
    List<String>? memberIds,
    List<String>? messageIds,
    bool clearAvatar = false,
    bool clearSummary = false,
  }) {
    return GroupChat(
      id: id ?? this.id,
      title: title ?? this.title,
      avatar: clearAvatar ? null : (avatar ?? this.avatar),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isPinned: isPinned ?? this.isPinned,
      settings: settings ?? this.settings,
      summary: clearSummary ? null : (summary ?? this.summary),
      memberIds: memberIds ?? this.memberIds,
      messageIds: messageIds ?? this.messageIds,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'avatar': avatar,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'isPinned': isPinned,
      'settings': settings.toJson(),
      'summary': summary,
      'memberIds': memberIds,
      'messageIds': messageIds,
    };
  }

  factory GroupChat.fromJson(Map<String, dynamic> json) {
    final settingsRaw = json['settings'];
    Map<String, dynamic>? settingsMap;
    if (settingsRaw is Map) {
      settingsMap = settingsRaw.map((k, v) => MapEntry(k.toString(), v));
    } else if (settingsRaw is String && settingsRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(settingsRaw);
        if (decoded is Map) {
          settingsMap = decoded.map((k, v) => MapEntry(k.toString(), v));
        }
      } catch (_) {
        settingsMap = null;
      }
    }

    return GroupChat(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      avatar: json['avatar'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      isPinned: json['isPinned'] as bool? ?? false,
      settings: GroupChatSettings.fromJson(settingsMap),
      summary: json['summary'] as String?,
      memberIds:
          (json['memberIds'] as List?)?.map((e) => e.toString()).toList() ??
          <String>[],
      messageIds:
          (json['messageIds'] as List?)?.map((e) => e.toString()).toList() ??
          <String>[],
    );
  }
}
