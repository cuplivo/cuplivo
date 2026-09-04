import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/workspace.dart';
import '../../../core/providers/workspace_provider.dart';
import '../../../core/services/saf/saf_mount_sync_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/ios_settings_section.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';

class WorkspaceSafMountsPage extends StatelessWidget {
  const WorkspaceSafMountsPage({super.key, required this.workspaceId});

  final String workspaceId;

  Future<void> _pickAndAdd(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final service = context.read<SafMountSyncService>();
    Map<String, dynamic>? picked;
    try {
      picked = await service.pickTree();
    } catch (e) {
      debugPrint('WorkspaceSafMountsPage._pickAndAdd: $e');
      if (context.mounted) {
        showAppSnackBar(context, message: l10n.safMountErrorPickFailed);
      }
      return;
    }
    if (picked == null || !context.mounted) return;
    final uri = (picked['uri'] ?? '').toString();
    final displayName = (picked['displayName'] ?? '').toString();
    if (uri.isEmpty) return;

    final controller = TextEditingController();
    String? errorText;
    var saving = false;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: Text(l10n.safMountAddTitle),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  displayName.isEmpty ? uri : displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(
                      dialogContext,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 8),
                IosFormTextField(
                  label: l10n.safMountAliasLabel,
                  controller: controller,
                  hintText: l10n.safMountAliasHint,
                  autofocus: true,
                  maxLength: 32,
                  inlineLabel: false,
                  outerPadding: EdgeInsets.zero,
                  enabled: !saving,
                ),
                if (errorText != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    errorText!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(dialogContext).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(dialogContext),
                child: Text(l10n.workspaceCancel),
              ),
              TextButton(
                onPressed: saving
                    ? null
                    : () async {
                        setDialogState(() {
                          saving = true;
                          errorText = null;
                        });
                        String? error;
                        try {
                          error = await service.addMount(
                            workspaceId: workspaceId,
                            alias: controller.text,
                            uri: uri,
                            displayName: displayName,
                          );
                        } catch (e) {
                          debugPrint(
                            'WorkspaceSafMountsPage._pickAndAdd save: $e',
                          );
                          error = 'save_failed';
                        }
                        if (!dialogContext.mounted) return;
                        if (error == null) {
                          Navigator.pop(dialogContext);
                          return;
                        }
                        setDialogState(() {
                          saving = false;
                          errorText = switch (error) {
                            SafMountSyncService.errorAliasInvalid =>
                              l10n.safMountErrorAliasInvalid,
                            SafMountSyncService.errorAliasReserved =>
                              l10n.safMountErrorAliasReserved,
                            SafMountSyncService.errorAliasDuplicate =>
                              l10n.safMountErrorAliasDuplicate,
                            SafMountSyncService.errorUriDuplicate =>
                              l10n.safMountErrorUriDuplicate,
                            SafMountSyncService.errorTerminalStopFailed =>
                              l10n.workspaceTerminalStopFailed,
                            _ => l10n.safMountErrorAddFailed,
                          };
                        });
                      },
                child: Text(l10n.workspaceConfirm),
              ),
            ],
          ),
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _confirmRemove(
    BuildContext context,
    WorkspaceSafMount entry,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.safMountRemoveTitle),
        content: Text(
          l10n.safMountRemoveMessage(
            entry.displayName.isEmpty ? entry.alias : entry.displayName,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.workspaceCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.workspaceConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await context.read<SafMountSyncService>().removeMount(
        workspaceId,
        entry.id,
      );
    } catch (error) {
      debugPrint('WorkspaceSafMountsPage._confirmRemove: $error');
      if (context.mounted) {
        showAppSnackBar(context, message: l10n.workspaceTerminalStopFailed);
      }
    }
  }

  String _statusLabel(AppLocalizations l10n, SafMountState state) =>
      switch (state.status) {
        SafMountStatus.idle => l10n.safMountStatusIdle,
        SafMountStatus.syncing => l10n.safMountStatusSyncing,
        SafMountStatus.unavailable => l10n.safMountStatusUnavailable,
        SafMountStatus.error => l10n.safMountStatusError,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final workspace = context.watch<WorkspaceProvider>().getById(workspaceId);
    final service = context.watch<SafMountSyncService>();
    if (workspace == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.safMountSectionTitle)),
        body: Center(child: Text(l10n.workspaceNotFound)),
      );
    }
    final entries = service.entriesFor(workspaceId);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.safMountSectionTitle),
        actions: [
          IconButton(
            tooltip: l10n.safMountAdd,
            onPressed: () => _pickAndAdd(context),
            icon: const Icon(Lucide.Plus),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          if (entries.isEmpty)
            IosSettingsSection(
              children: [
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(l10n.safMountEmpty),
                ),
              ],
            )
          else
            IosSettingsSection(
              children: [
                for (var i = 0; i < entries.length; i++) ...[
                  if (i > 0) const IosSettingsDivider(),
                  _SafMountRow(
                    entry: entries[i],
                    state: service.stateOf(entries[i].id),
                    statusLabel: _statusLabel(
                      l10n,
                      service.stateOf(entries[i].id),
                    ),
                    onSync: () => service.syncNow(entries[i].id),
                    onRemove: () => _confirmRemove(context, entries[i]),
                  ),
                ],
              ],
            ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              l10n.safMountSectionNote,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.58),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SafMountRow extends StatelessWidget {
  const _SafMountRow({
    required this.entry,
    required this.state,
    required this.statusLabel,
    required this.onSync,
    required this.onRemove,
  });

  final WorkspaceSafMount entry;
  final SafMountState state;
  final String statusLabel;
  final VoidCallback onSync;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final syncing = state.status == SafMountStatus.syncing;
    final failed =
        state.status == SafMountStatus.unavailable ||
        state.status == SafMountStatus.error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '@${entry.alias}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: AppFontWeights.semibold,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  entry.displayName.isEmpty ? entry.uri : entry.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.58),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  statusLabel,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: failed
                        ? cs.error
                        : cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
          IosIconButton(
            icon: syncing ? Lucide.Loader : Lucide.RefreshCw,
            size: 15,
            minSize: 30,
            semanticLabel: l10n.safMountSyncNow,
            onTap: syncing ? null : onSync,
          ),
          IosIconButton(
            icon: Lucide.Trash2,
            size: 15,
            minSize: 30,
            semanticLabel: l10n.safMountRemove,
            onTap: onRemove,
          ),
        ],
      ),
    );
  }
}
