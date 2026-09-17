/// Member of a group chat. User is always first (`memberKey == userKey`).
class GroupChatMember {
  const GroupChatMember({
    required this.groupChatId,
    required this.memberKey,
    this.assistantId,
    required this.sortOrder,
  });

  static const String userKey = 'user';

  final String groupChatId;

  /// `user` for the human, or the assistant id for assistant members.
  final String memberKey;
  final String? assistantId;
  final int sortOrder;

  bool get isUser => memberKey == userKey;

  Map<String, dynamic> toJson() => {
    'groupChatId': groupChatId,
    'memberKey': memberKey,
    'assistantId': assistantId,
    'sortOrder': sortOrder,
  };

  factory GroupChatMember.fromJson(Map<String, dynamic> json) {
    return GroupChatMember(
      groupChatId: json['groupChatId'] as String,
      memberKey: json['memberKey'] as String,
      assistantId: json['assistantId'] as String?,
      sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
    );
  }

  factory GroupChatMember.user({
    required String groupChatId,
    int sortOrder = 0,
  }) {
    return GroupChatMember(
      groupChatId: groupChatId,
      memberKey: userKey,
      assistantId: null,
      sortOrder: sortOrder,
    );
  }

  factory GroupChatMember.assistant({
    required String groupChatId,
    required String assistantId,
    required int sortOrder,
  }) {
    return GroupChatMember(
      groupChatId: groupChatId,
      memberKey: assistantId,
      assistantId: assistantId,
      sortOrder: sortOrder,
    );
  }
}
