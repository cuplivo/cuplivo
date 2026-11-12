import 'package:Cuplivo/core/services/sync/sync_family_registry.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/sync_payload.dart';

/// What a conversation subtree carries and how it says so.
///
/// The point of these cases is that the answer comes from the registration: a
/// family added there changes the payload with no edit to
/// [SyncSubtreePayload]'s fields, and the wire still speaks the keys the
/// registry names.
void main() {
  test('the payload speaks exactly the registered wire keys', () {
    final payload = subtreePayload(
      conversation: {'id': 'c1', 'updated_at': 1},
      messages: [
        {'id': 'm1', 'conversation_id': 'c1'},
      ],
      parts: [
        {'revision_id': 'm1', 'ordinal': 0, 'kind': 'text', 'payload': 'hi'},
      ],
      mcpServers: [
        {'conversation_id': 'c1', 'server_id': 's1', 'ordinal': 0},
      ],
    );
    expect(payload.toJson().keys.toSet(), {
      for (final family in syncedConversationFamilies) family.wireKey,
    }, reason: 'the wire is the registration, not a struct somebody grew');
  });

  test('a subtree survives a round trip through JSON', () {
    final before = subtreePayload(
      conversation: {'id': 'c1', 'updated_at': 1},
      messages: [
        {'id': 'm1', 'conversation_id': 'c1', 'message_order': 0},
      ],
      parts: [
        {'revision_id': 'm1', 'ordinal': 0, 'kind': 'text', 'payload': 'hi'},
      ],
      mcpServers: const [],
    );
    final after = SyncSubtreePayload.fromJson(before.toJson());
    expect(after.conversation, before.conversation);
    for (final family in syncedConversationFamilies) {
      expect(after.rowsOf(family), before.rowsOf(family), reason: family.name);
    }
  });

  test('the root family answers with the conversation row itself', () {
    final payload = subtreePayload(conversation: {'id': 'c1'});
    final root = syncedConversationFamilies.singleWhere(
      (family) => family.isSubtreeRoot,
    );
    expect(payload.rowsOf(root), [
      {'id': 'c1'},
    ]);
  });

  test('every row a payload carries is reachable through travellingRows', () {
    final payload = subtreePayload(
      conversation: {'id': 'c1'},
      messages: [
        {'id': 'm1'},
        {'id': 'm2'},
      ],
      parts: [
        {'revision_id': 'm1', 'ordinal': 0},
      ],
      mcpServers: [
        {'server_id': 's1', 'ordinal': 0},
      ],
    );
    expect(
      payload.travellingRows.length,
      1 + 2 + 1 + 1,
      reason: 'the root row plus one per registered family row',
    );
  });
}
