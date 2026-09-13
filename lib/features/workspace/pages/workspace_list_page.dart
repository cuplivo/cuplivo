import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/workspace.dart';
import '../../../core/providers/workspace_provider.dart';
import '../../../features/workspace/controllers/dependency_install_controller.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import 'workspace_detail_page.dart';

/// Opens the workspace add dialog. Shared by the mobile list page and the
/// desktop settings pane. Returns the created workspace (null on cancel,
/// empty name, or failure).
Future<Workspace?> showAddWorkspaceDialog(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final controller = TextEditingController();
  final provider = context.read<WorkspaceProvider>();
  try {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.workspaceAdd),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: l10n.workspaceNameHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.workspaceCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.workspaceConfirm),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return null;
    final name = controller.text.trim();
    if (name.isEmpty) return null;
    try {
      return await provider.createWorkspace(displayName: name);
    } catch (e) {
      if (context.mounted) {
        showAppSnackBar(context, message: e.toString());
      }
      return null;
    }
  } finally {
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  }
}

class WorkspaceListPage extends StatelessWidget {
  const WorkspaceListPage({
    super.key,
    this.embedded = false,
    this.onOpenWorkspace,
    this.selectedId,
    this.onDataChanged,
  });

  final bool embedded;

  /// When provided, tapping a card calls this instead of pushing
  /// [WorkspaceDetailPage] (used by the desktop master-detail pane).
  final ValueChanged<Workspace>? onOpenWorkspace;

  /// Highlights the card for this workspace id (master-detail selection).
  final String? selectedId;

  /// Fired after a workspace deletion succeeded (storage usage refresh).
  final VoidCallback? onDataChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final wp = context.watch<WorkspaceProvider>();
    final items = wp.workspaces;

    final body = !wp.loaded
        ? const Center(child: CircularProgressIndicator())
        : items.isEmpty
        ? Center(child: Text(l10n.workspaceListEmpty))
        : ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final ws = items[index];
              return Padding(
                key: ValueKey(ws.id),
                padding: const EdgeInsets.only(bottom: 10),
                child: _WorkspaceCard(
                  workspace: ws,
                  selected: ws.id == selectedId,
                  onTap: onOpenWorkspace != null
                      ? () => onOpenWorkspace!(ws)
                      : () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  WorkspaceDetailPage(workspaceId: ws.id),
                            ),
                          );
                        },
                  onDelete: ws.alias == Workspace.defaultAlias
                      ? null
                      : () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text(l10n.workspaceConfirm),
                              content: Text(ws.displayName),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: Text(l10n.workspaceCancel),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: Text(l10n.workspaceConfirm),
                                ),
                              ],
                            ),
                          );
                          if (ok != true || !context.mounted) return;
                          final err = await wp.deleteWorkspace(ws.id);
                          if (err == null && context.mounted) {
                            // Workspace no longer exists; drop the cached
                            // dep snapshot so a future workspace that
                            // reuses the id does not inherit a stale
                            // "base installed" snapshot from the deleted
                            // one.
                            context
                                .read<DependencyInstallController>()
                                .forgetWorkspace(ws.id);
                            onDataChanged?.call();
                          }
                          if (err != null && context.mounted) {
                            showAppSnackBar(
                              context,
                              message:
                                  err ==
                                      WorkspaceProvider.errorTerminalStopFailed
                                  ? l10n.workspaceTerminalStopFailed
                                  : l10n.workspaceCannotDeleteDefault,
                            );
                          }
                        },
                ),
              );
            },
          );

    if (embedded) return body;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settingsPageWorkspace),
        actions: [
          IconButton(
            tooltip: l10n.workspaceAdd,
            icon: Icon(Lucide.Plus, color: cs.onSurface),
            onPressed: () => showAddWorkspaceDialog(context),
          ),
        ],
      ),
      body: body,
    );
  }
}

class _WorkspaceCard extends StatelessWidget {
  const _WorkspaceCard({
    required this.workspace,
    required this.onTap,
    this.selected = false,
    this.onDelete,
  });

  final Workspace workspace;
  final VoidCallback onTap;
  final bool selected;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: context.appColors.surfaceCard,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: selected ? cs.primary.withValues(alpha: 0.06) : null,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? cs.primary.withValues(alpha: 0.55)
                  : cs.outlineVariant.withValues(alpha: 0.12),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Lucide.FolderOpen, color: cs.primary, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      workspace.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: AppFontWeights.semibold,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '@${workspace.alias}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ),
              ),
              if (onDelete != null)
                IconButton(
                  icon: Icon(
                    Lucide.Trash2,
                    size: 18,
                    color: cs.error.withValues(alpha: 0.85),
                  ),
                  onPressed: onDelete,
                ),
              Icon(
                Lucide.ChevronRight,
                size: 18,
                color: cs.onSurface.withValues(alpha: 0.35),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
