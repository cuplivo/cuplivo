import 'package:flutter/foundation.dart';

/// A group chat: a named roster of assistants one conversation can talk to.
///
/// A group owns *many* conversations (topics); the link lives on the
/// conversation (`extras['groupChat.id']`), never on the group. The payload
/// below is therefore only the group itself — its roster, its name and how many
/// speakers one round may take.
class GroupChat {
  const GroupChat({
    required this.id,
    required this.name,
    this.avatar,
    required this.memberIds,
    this.maxSpeakerTurns = defaultMaxSpeakerTurns,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Speakers one round may take, inclusive. A round stops when the director
  /// ends it, when it runs out of members, or at this cap.
  static const int minSpeakerTurns = 1;
  static const int maxSpeakerTurnsLimit = 6;
  static const int defaultMaxSpeakerTurns = 3;

  /// Payload shape this build writes. A row from a newer build is skipped
  /// rather than guessed at.
  static const int payloadVersion = 1;

  final String id;
  final String name;

  /// Emoji, a URL, or a local file path — the same three shapes
  /// [AssistantAvatar] resolves for an assistant.
  final String? avatar;

  final List<String> memberIds;
  final int maxSpeakerTurns;
  final DateTime createdAt;
  final DateTime updatedAt;

  int get speakerTurnLimit =>
      maxSpeakerTurns.clamp(minSpeakerTurns, maxSpeakerTurnsLimit);

  GroupChat copyWith({
    String? id,
    String? name,
    String? avatar,
    List<String>? memberIds,
    int? maxSpeakerTurns,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool clearAvatar = false,
  }) {
    return GroupChat(
      id: id ?? this.id,
      name: name ?? this.name,
      avatar: clearAvatar ? null : (avatar ?? this.avatar),
      memberIds: memberIds ?? this.memberIds,
      maxSpeakerTurns: maxSpeakerTurns ?? this.maxSpeakerTurns,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'v': payloadVersion,
    'id': id,
    'name': name,
    'avatar': avatar,
    'memberIds': memberIds,
    'maxSpeakerTurns': speakerTurnLimit,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  /// Decodes one stored payload, or throws [FormatException] when it is not a
  /// group this build understands.
  factory GroupChat.fromJson(Map<String, dynamic> json) {
    final version = json['v'];
    if (version != null && version != payloadVersion) {
      throw FormatException('group_chat_version:$version');
    }
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('group_chat_id');
    }
    final rawMembers = json['memberIds'];
    final memberIds = <String>[
      if (rawMembers is List)
        for (final entry in rawMembers)
          if (entry is String && entry.isNotEmpty) entry,
    ];
    final createdAt = DateTime.tryParse((json['createdAt'] ?? '').toString());
    final updatedAt = DateTime.tryParse((json['updatedAt'] ?? '').toString());
    if (createdAt == null || updatedAt == null) {
      throw const FormatException('group_chat_timestamps');
    }
    final turns = json['maxSpeakerTurns'];
    return GroupChat(
      id: id,
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : '',
      avatar: (json['avatar'] as String?)?.trim().isNotEmpty == true
          ? json['avatar'] as String
          : null,
      memberIds: List<String>.unmodifiable(memberIds.toSet()),
      maxSpeakerTurns: turns is num
          ? turns.toInt().clamp(minSpeakerTurns, maxSpeakerTurnsLimit)
          : defaultMaxSpeakerTurns,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is GroupChat &&
            other.id == id &&
            other.name == name &&
            other.avatar == avatar &&
            listEquals(other.memberIds, memberIds) &&
            other.maxSpeakerTurns == maxSpeakerTurns &&
            other.createdAt == createdAt &&
            other.updatedAt == updatedAt;
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    avatar,
    Object.hashAll(memberIds),
    maxSpeakerTurns,
    createdAt,
    updatedAt,
  );
}
