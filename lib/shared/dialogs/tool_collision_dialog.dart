import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/assistant.dart';
import '../../core/providers/assistant_provider.dart';
import '../../core/providers/mcp_provider.dart';
import '../../features/home/services/tool_handler_service.dart';
import '../../features/home/services/local_tools_service.dart';
import '../../features/linux_sandbox/models/linux_sandbox.dart';
import '../../l10n/app_localizations.dart';
import '../widgets/ios_tactile.dart';

class _CollisionResolution {
  final String toolName;
  bool builtinDisabled = false;
  final Set<String> serverIds; // server IDs involved in this collision
  final Set<String> serversToUnbind;

  _CollisionResolution({
    required this.toolName,
    required this.serverIds,
    required this.serversToUnbind,
  });

  bool isResolved(Map<String, TextEditingController> sharedControllers) {
    final prefixedCount = serverIds
        .where((id) => sharedControllers[id]?.text.trim().isNotEmpty ?? false)
        .length;
    final unbindCount = serversToUnbind.length;
    // ≥ N−1 servers prefixed or unbound is sufficient (one clean name may stay)
    final disambiguated = (prefixedCount + unbindCount) >= serverIds.length - 1;
    return (builtinDisabled && serverIds.length == 1) ||
        disambiguated ||
        (unbindCount == serverIds.length);
  }
}

Future<bool> showMcpToolCollisionDialog({
  required BuildContext context,
  required List<ToolNameCollision> collisions,
  required McpProvider mcp,
  required Assistant? assistant,
  required AppLocalizations l10n,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _ToolCollisionDialogBody(
      initialCollisions: collisions,
      assistant: assistant,
    ),
  );
  return result ?? false;
}

class _ToolCollisionDialogBody extends StatefulWidget {
  final List<ToolNameCollision> initialCollisions;
  final Assistant? assistant;

  const _ToolCollisionDialogBody({
    required this.initialCollisions,
    required this.assistant,
  });

  @override
  State<_ToolCollisionDialogBody> createState() =>
      _ToolCollisionDialogBodyState();
}

class _ToolCollisionDialogBodyState extends State<_ToolCollisionDialogBody> {
  late List<_CollisionResolution> _resolutions;
  bool _saving = false;

  /// Shared prefix controllers keyed by server ID.
  /// A single server appearing in multiple collisions uses the same controller,
  /// so editing the prefix in one collision tile updates all others.
  final Map<String, TextEditingController> _sharedPrefixControllers = {};
  final Map<String, String?> _prefixErrors = {};

  @override
  void initState() {
    super.initState();
    _resolutions = widget.initialCollisions.map((c) {
      return _CollisionResolution(
        toolName: c.toolName,
        serverIds: c.servers.map((s) => s.id).toSet(),
        serversToUnbind: <String>{},
      );
    }).toList();

    // Create one controller per unique server ID across all collisions
    final allServerIds = <String>{};
    for (final c in widget.initialCollisions) {
      for (final s in c.servers) {
        allServerIds.add(s.id);
      }
    }
    for (final id in allServerIds) {
      // Find the server config to get its current toolPrefix
      for (final c in widget.initialCollisions) {
        final match = c.servers.where((s) => s.id == id);
        if (match.isNotEmpty) {
          _sharedPrefixControllers[id] = TextEditingController(
            text: match.first.toolPrefix,
          );
          _prefixErrors[id] = null;
          break;
        }
      }
    }
  }

  @override
  void dispose() {
    for (final c in _sharedPrefixControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _allResolved =>
      _resolutions.every((r) => r.isResolved(_sharedPrefixControllers)) &&
      !_prefixErrors.values.any((e) => e != null);

  void _validatePrefix(String serverId, McpServerConfig server) {
    final text = _sharedPrefixControllers[serverId]!.text.trim();
    final error = ToolHandlerService.validateToolPrefix(text, server);
    setState(() {
      _prefixErrors[serverId] = error;
    });
  }

  Future<void> _applyAndSave() async {
    setState(() => _saving = true);
    try {
      final mcp = context.read<McpProvider>();
      final assistantProvider = context.read<AssistantProvider>();

      // Collect all unique servers across collisions
      final allServers = <String, McpServerConfig>{};
      for (final c in widget.initialCollisions) {
        for (final s in c.servers) {
          allServers[s.id] = s;
        }
      }

      // Collect all server IDs to unbind (from any collision)
      final serverIdsToUnbind = <String>{};
      for (final r in _resolutions) {
        serverIdsToUnbind.addAll(r.serversToUnbind);
      }

      // Apply prefixes (MCP server changes, not assistant)
      for (final entry in _sharedPrefixControllers.entries) {
        final serverId = entry.key;
        if (serverIdsToUnbind.contains(serverId)) continue;
        final newPrefix = entry.value.text.trim();
        final server = allServers[serverId]!;
        if (newPrefix != server.toolPrefix) {
          await mcp.updateServer(server.copyWith(toolPrefix: newPrefix));
        }
      }

      // Accumulate all assistant changes into a single copyWith chain
      if (widget.assistant != null) {
        Assistant modified = widget.assistant!;

        // Unbind servers
        if (serverIdsToUnbind.isNotEmpty) {
          modified = modified.copyWith(
            mcpServerIds: modified.mcpServerIds
                .where((id) => !serverIdsToUnbind.contains(id))
                .toList(),
          );
        }

        // Disable built-ins (chain from modified, not original snapshot)
        for (int i = 0; i < _resolutions.length; i++) {
          final r = _resolutions[i];
          final collision = widget.initialCollisions[i];
          if (!r.builtinDisabled ||
              collision.source != CollisionSource.builtin) {
            continue;
          }
          final toolName = collision.toolName;
          if (toolName == 'search_web') {
            modified = modified.copyWith(searchEnabled: false);
          } else if (toolName == 'create_memory' ||
              toolName == 'edit_memory' ||
              toolName == 'delete_memory' ||
              toolName == 'read_memory') {
            modified = modified.copyWith(enableMemory: false);
          } else if (toolName == LocalToolNames.loadSkill ||
              toolName == LocalToolNames.readSkillFile) {
            // Skill tools are gated by skillIds, not localToolIds
            modified = modified.copyWith(skillIds: const <String>[]);
          } else if (LinuxSandboxToolNames.all.contains(toolName)) {
            modified = modified.copyWith(
              sandboxEnabled: false,
              clearSandboxId: true,
            );
          } else {
            // Local tools
            modified = modified.copyWith(
              localToolIds: modified.localToolIds
                  .where((id) => id != toolName)
                  .toList(),
            );
          }
        }

        // Single save call with all accumulated changes
        await assistantProvider.updateAssistant(modified);
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final mcp = context.read<McpProvider>();

    if (_saving) {
      return AlertDialog(
        content: SizedBox(
          height: 80,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return AlertDialog(
      title: Text(l10n.mcpToolCollisionTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.mcpToolCollisionDescription),
            const SizedBox(height: 12),
            for (int i = 0; i < widget.initialCollisions.length; i++) ...[
              if (i > 0) const Divider(),
              _buildCollisionTile(i, widget.initialCollisions[i], l10n, mcp),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.mcpToolCollisionCancel),
        ),
        ElevatedButton(
          onPressed: _allResolved ? _applyAndSave : null,
          child: Text(l10n.mcpToolCollisionConfirm),
        ),
      ],
    );
  }

  Widget _buildCollisionTile(
    int idx,
    ToolNameCollision collision,
    AppLocalizations l10n,
    McpProvider mcp,
  ) {
    final r = _resolutions[idx];
    final isBuiltin = collision.source == CollisionSource.builtin;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '`${collision.toolName}`',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          isBuiltin
              ? l10n.mcpToolCollisionBuiltinDesc
              : l10n.mcpToolCollisionMcpDesc,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (isBuiltin)
          IosCardPress(
            onTap: () => setState(() => r.builtinDisabled = !r.builtinDisabled),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    r.builtinDisabled
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(l10n.mcpToolCollisionDisableBuiltin)),
                ],
              ),
            ),
          ),
        if (isBuiltin && r.builtinDisabled) const SizedBox(height: 4),
        for (final server in collision.servers) ...[
          const SizedBox(height: 8),
          Text(
            '${l10n.mcpToolCollisionServerPrefix} ${server.name}',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _sharedPrefixControllers[server.id],
                  decoration: InputDecoration(
                    hintText: l10n.mcpToolCollisionPrefixHint,
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    errorText: _prefixErrors[server.id] != null
                        ? l10n.mcpToolCollisionPrefixError
                        : null,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                  ),
                  onChanged: (_) => _validatePrefix(
                    server.id,
                    mcp.servers.firstWhere((s) => s.id == server.id),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IosCardPress(
                onTap: () {
                  setState(() {
                    if (r.serversToUnbind.contains(server.id)) {
                      r.serversToUnbind.remove(server.id);
                    } else {
                      r.serversToUnbind.add(server.id);
                    }
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(
                    r.serversToUnbind.contains(server.id)
                        ? Icons.link_off
                        : Icons.link,
                    size: 20,
                    color: r.serversToUnbind.contains(server.id)
                        ? Colors.red
                        : null,
                  ),
                ),
              ),
            ],
          ),
          if (r.serversToUnbind.contains(server.id))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                l10n.mcpToolCollisionUnbindHint,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.red),
              ),
            ),
        ],
      ],
    );
  }
}
