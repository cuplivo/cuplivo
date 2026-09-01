import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../database/business_preferences.dart';
import '../../providers/assistant_provider.dart';
import '../../providers/group_chat_provider.dart';
import '../../providers/mcp_provider.dart';
import '../../providers/workspace_provider.dart';
import '../chat/chat_service.dart';
import '../proactive_care_alarm_service.dart';
import '../saf/saf_mount_sync_service.dart';

/// Re-reads every provider that mirrors persisted state after a restore /
/// import rewrote SQLite or SharedPreferences, so the UI does not keep a
/// cleared or pre-restore in-memory snapshot.
///
/// Single shared refresh list for all restore entry points (mobile backup
/// page, desktop backup pane, LAN sync). Any new provider that persists state
/// must subscribe here; adding reloads at individual call sites is what let
/// the refresh list drift out of sync before.
Future<void> refreshProvidersAfterRestore(BuildContext context) async {
  final chatService = context.read<ChatService>();
  final assistantProvider = context.read<AssistantProvider>();
  final groupChatProvider = context.read<GroupChatProvider>();
  final mcpProvider = context.read<McpProvider>();
  final workspaceProvider = context.read<WorkspaceProvider>();
  final safMounts = context.read<SafMountSyncService>();
  // Business preferences: the facade cache must re-read the KV table — a
  // restored/merged settings payload was written through the facade, so the
  // cache is already co-evolved, but a wipe+restore (or import) may have
  // replaced the whole table behind the facade's back.
  try {
    await context.read<BusinessPreferences>().reload();
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: BusinessPreferences: $e');
  }
  try {
    await chatService.repo.transferLegacyProactiveCareSchedules();
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: proactive-care migration: $e');
  }
  try {
    await chatService.reloadCachesFromDb();
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: ChatService: $e');
  }
  try {
    await workspaceProvider.reloadFromPrefs();
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: WorkspaceProvider: $e');
  }
  try {
    await safMounts.reloadAfterRestore();
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: SafMountSyncService: $e');
  }
  try {
    // Reload MCP BEFORE assistants: reloading assistants can fire provider
    // change notifications that read the server list. If the old client
    // were still live at that point it would write the pre-restore list
    // over the restored mcp_servers_v1; reloading MCP first means any such
    // refresh runs against the new client (or no client) and stays
    // harmless.
    await mcpProvider.reloadFromPrefs();
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: McpProvider: $e');
  }
  try {
    await assistantProvider.reloadFromRepo();
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: AssistantProvider: $e');
  }
  try {
    await ProactiveCareAlarmService.rescheduleAll(
      conversations: chatService.getAllConversations(),
      assistants: assistantProvider.assistants,
    );
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: proactive-care alarms: $e');
  }
  try {
    await groupChatProvider.load();
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: GroupChatProvider: $e');
  }
}
