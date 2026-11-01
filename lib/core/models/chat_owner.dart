/// One row of the sidebar's chat list: an assistant, or a group chat.
///
/// Both kinds share a single ordered list (and a single drag order), because a
/// user looking for "who do I talk to" does not care which storage shape the
/// row has. [key] is the stable identity that order is persisted under.
enum ChatOwnerKind { assistant, group }

class ChatOwner {
  const ChatOwner(this.kind, this.id);

  const ChatOwner.assistant(String id) : this(ChatOwnerKind.assistant, id);
  const ChatOwner.group(String id) : this(ChatOwnerKind.group, id);

  final ChatOwnerKind kind;
  final String id;

  bool get isGroup => kind == ChatOwnerKind.group;

  String get key => switch (kind) {
    ChatOwnerKind.assistant => 'assistant:$id',
    ChatOwnerKind.group => 'group:$id',
  };

  static ChatOwner? tryParse(String key) {
    final separator = key.indexOf(':');
    if (separator <= 0) return null;
    final id = key.substring(separator + 1);
    if (id.isEmpty) return null;
    switch (key.substring(0, separator)) {
      case 'assistant':
        return ChatOwner.assistant(id);
      case 'group':
        return ChatOwner.group(id);
      default:
        return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatOwner && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => key;
}
