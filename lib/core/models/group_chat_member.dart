import 'package:uuid/uuid.dart';

/// Member of a multi-assistant [GroupChat].
///
/// [kind] is `'user'` or `'assistant'`. User is always present and not removable
/// at the product layer; [assistantId] is set only for assistant members.
///
/// copyWith uses the plain `??` pattern (same as [Conversation]).
class GroupChatMember {
  static const String kindUser = 'user';
  static const String kindAssistant = 'assistant';

  final String id;
  final String groupId;
  final String kind;
  final String? assistantId;
  final int sortOrder;
  final bool isEnabled;
  final DateTime createdAt;

  GroupChatMember({
    String? id,
    required this.groupId,
    required this.kind,
    this.assistantId,
    this.sortOrder = 0,
    this.isEnabled = true,
    DateTime? createdAt,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now();

  bool get isUser => kind == kindUser;
  bool get isAssistant => kind == kindAssistant;

  GroupChatMember copyWith({
    String? id,
    String? groupId,
    String? kind,
    String? assistantId,
    int? sortOrder,
    bool? isEnabled,
    DateTime? createdAt,
    bool clearAssistantId = false,
  }) {
    return GroupChatMember(
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
      kind: kind ?? this.kind,
      assistantId: clearAssistantId ? null : (assistantId ?? this.assistantId),
      sortOrder: sortOrder ?? this.sortOrder,
      isEnabled: isEnabled ?? this.isEnabled,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'groupId': groupId,
      'kind': kind,
      'assistantId': assistantId,
      'sortOrder': sortOrder,
      'isEnabled': isEnabled,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory GroupChatMember.fromJson(Map<String, dynamic> json) {
    return GroupChatMember(
      id: json['id'] as String,
      groupId: json['groupId'] as String,
      kind: json['kind'] as String,
      assistantId: json['assistantId'] as String?,
      sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
      isEnabled: json['isEnabled'] as bool? ?? true,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}
