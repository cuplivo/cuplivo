import '../../../core/models/assistant.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/conversation_mcp_settings.dart';
import '../../home/services/local_tool_labels.dart';

/// What one member has switched on, out of what it could: device-local tools
/// plus the connected MCP servers it selects.
///
/// The member strip has room for one number, and this is the one the tools panel
/// is about — the same pair its two group headers report one each. A member with
/// nothing on returns `enabled == 0`, which the strip renders as nothing rather
/// than as a zero.
({int enabled, int total}) memberToolSummary(
  Assistant member, {
  Conversation? conversation,
  required Iterable<String> connectedServerIds,
}) {
  final connected = connectedServerIds.toSet();
  final localIds = availableLocalToolIds().toSet();
  final enabledLocal = member.localToolIds.where(localIds.contains).length;
  final enabledServers = ConversationMcpSettings.effectiveServerIds(
    member,
    conversation,
  ).where(connected.contains).length;
  return (
    enabled: enabledLocal + enabledServers,
    total: localIds.length + connected.length,
  );
}
