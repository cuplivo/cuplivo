import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../core/providers/group_chat_provider.dart';
import '../home/controllers/chat_actions.dart';

/// Deletes a group the one way every host does it.
///
/// A group takes its topics with it, so the same invariant as assistant
/// deletion applies: deleting implies stopping. A round still writing into one
/// of those topics would otherwise checkpoint against rows that no longer exist.
Future<void> deleteGroupChat(BuildContext context, String groupId) async {
  await ChatActions.cancelActiveGenerationsForGroup(groupId);
  if (!context.mounted) return;
  await context.read<GroupChatProvider>().delete(groupId);
}
