import 'package:Cuplivo/core/services/sync/sync_family_registry.dart';
import 'package:Cuplivo/core/services/sync/sync_models.dart';

/// A subtree payload assembled from the families a test cares about, keyed the
/// same way `readSubtree` keys them.
///
/// Tests name rows by what they are — messages, parts, MCP bindings — while the
/// payload carries them by registered family name. This is the one place that
/// translation happens, so a rename in the registry does not reach every test's
/// constructor call.
SyncSubtreePayload subtreePayload({
  required Map<String, dynamic> conversation,
  List<Map<String, dynamic>> messages = const [],
  List<Map<String, dynamic>> parts = const [],
  List<Map<String, dynamic>> mcpServers = const [],
}) => SyncSubtreePayload(
  conversation: conversation,
  families: {
    syncFamilyOfTable('message_rows').name: messages,
    syncFamilyOfTable('message_part_rows').name: parts,
    syncFamilyOfTable('conversation_mcp_server_rows').name: mcpServers,
  },
);
