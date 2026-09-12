import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/knowledge.dart';
import '../../core/providers/knowledge_provider.dart';
import '../../core/services/haptics.dart';
import '../../core/services/knowledge/knowledge_import_service.dart';
import '../../features/knowledge/widgets/knowledge_base_editor.dart';
import '../../features/knowledge/widgets/knowledge_document_list.dart';
import '../../features/knowledge/widgets/knowledge_import_result_dialog.dart';
import '../../features/knowledge/widgets/knowledge_unbound_chip.dart';
import '../../icons/lucide_adapter.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/widgets/assistant_bind_multi_select.dart';
import '../../shared/widgets/ios_switch.dart';
import '../../shared/widgets/ios_tactile.dart';
import '../../shared/widgets/snackbar.dart';
import '../../theme/app_font_weights.dart';
import '../../theme/app_semantic_colors.dart';
import '../desktop_tab_bus.dart';

/// Desktop knowledge base settings pane (issue #389): master-detail with the
/// base list on the left and the selected base's documents on the right.
class DesktopKnowledgePane extends StatefulWidget {
  const DesktopKnowledgePane({super.key});

  @override
  State<DesktopKnowledgePane> createState() => _DesktopKnowledgePaneState();
}

class _DesktopKnowledgePaneState extends State<DesktopKnowledgePane> {
  String? _selectedBaseId;
  bool _dragHovering = false;
  int _importRefreshToken = 0;

  KnowledgeBase? _selectedBase(KnowledgeProvider provider) {
    final bases = provider.bases;
    return (_selectedBaseId == null
            ? null
            : provider.getById(_selectedBaseId!)) ??
        (bases.isEmpty ? null : bases.first);
  }

  Future<void> _handleDrop(List<KnowledgeImportFile> files) async {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.read<KnowledgeProvider>();
    final base = _selectedBase(provider);
    if (base == null) {
      showAppSnackBar(
        context,
        message: l10n.knowledgeDropNoBase,
        type: NotificationType.warning,
      );
      return;
    }
    if (files.isEmpty) return;
    final results = await provider.importFiles(base.id, files);
    if (!mounted) return;
    // Force the document list to re-read (it owns its own load lifecycle).
    setState(() => _importRefreshToken++);
    showKnowledgeImportResult(context, results);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await context.read<KnowledgeProvider>().initialize();
    });
  }

  Future<void> _createBase() async {
    final provider = context.read<KnowledgeProvider>();
    final draft = await showKnowledgeBaseEditor(
      context,
      activeAssistantIdsFor: provider.activeBaseIdsFor,
    );
    if (draft == null || !mounted) return;
    final base = await provider.createBase(
      name: draft.name,
      description: draft.description,
      chunkSize: draft.chunkSize,
      chunkOverlap: draft.chunkOverlap,
    );
    if (!mounted) return;
    await applyKnowledgeBaseBindings(
      context,
      itemId: base.id,
      selectedAssistantIds: draft.selectedAssistantIds,
    );
    if (!mounted) return;
    setState(() => _selectedBaseId = base.id);
  }

  Future<void> _deleteBase(KnowledgeBase base) async {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.read<KnowledgeProvider>();
    final confirmed = await confirmKnowledgeAction(
      context,
      title: l10n.knowledgeDeleteTitle,
      message: l10n.knowledgeDeleteMessage(
        base.name.trim().isEmpty ? l10n.knowledgeUnnamed : base.name,
      ),
      confirmLabel: l10n.knowledgeDelete,
    );
    if (!confirmed || !mounted) return;
    await provider.deleteBase(base.id);
    if (!mounted) return;
    setState(() => _selectedBaseId = null);
    showAppSnackBar(
      context,
      message: l10n.knowledgeDeleted(base.name),
      type: NotificationType.success,
    );
  }

  Future<void> _showChunks(KnowledgeDocument document) async {
    final l10n = AppLocalizations.of(context)!;
    final chunks = await context.read<KnowledgeProvider>().chunksForDocument(
      document.id,
    );
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          document.name.trim().isEmpty ? l10n.knowledgeUnnamed : document.name,
        ),
        content: SizedBox(
          width: 560,
          height: 460,
          child: ListView.builder(
            itemCount: chunks.length,
            itemBuilder: (context, index) {
              final chunk = chunks[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          l10n.knowledgeChunkIndex(chunk.chunkIndex + 1),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: AppFontWeights.semibold,
                            color: cs.primary,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          l10n.knowledgeCharCount(chunk.charCount),
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withValues(alpha: 0.55),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      chunk.content,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: cs.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.knowledgeImportOk),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.watch<KnowledgeProvider>();
    final bases = provider.bases;
    final selected = _selectedBase(provider);

    final body = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 280,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                child: Row(
                  children: [
                    Text(
                      l10n.knowledgePageTitle,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: AppFontWeights.semibold,
                        color: cs.onSurface,
                      ),
                    ),
                    const Spacer(),
                    IosIconButton(
                      icon: Lucide.Plus,
                      size: 20,
                      minSize: 40,
                      semanticLabel: l10n.knowledgeAdd,
                      onTap: () async {
                        Haptics.light();
                        await _createBase();
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: bases.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            l10n.knowledgePageEmpty,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurface.withValues(alpha: 0.55),
                            ),
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                        children: [
                          for (final base in bases)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _DesktopBaseTile(
                                base: base,
                                stats: provider.statsForSync(base.id),
                                selected: selected?.id == base.id,
                                onOpen: () =>
                                    setState(() => _selectedBaseId = base.id),
                                onDelete: () => _deleteBase(base),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
        VerticalDivider(width: 1, color: cs.outlineVariant),
        Expanded(
          child: selected == null
              ? Center(
                  child: Text(
                    l10n.knowledgePageEmpty,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: Text(
                        selected.name.trim().isEmpty
                            ? l10n.knowledgeUnnamed
                            : selected.name,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: AppFontWeights.semibold,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        child: KnowledgeDocumentList(
                          key: ValueKey(
                            'knowledge-docs-${selected.id}-$_importRefreshToken',
                          ),
                          baseId: selected.id,
                          onOpenDocument: _showChunks,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );

    // Desktop-only drop target: import dropped files into the selected base.
    // `enable` is gated on the active shell tab because desktop_drop fires for
    // every DropTarget under the cursor, even one laid out behind the
    // IndexedStack (see DesktopTabBus).
    return ListenableBuilder(
      listenable: DesktopTabBus.instance,
      builder: (context, _) => DropTarget(
        enable: DesktopTabBus.instance.index == DesktopTabBus.settings,
        onDragEntered: (_) => setState(() => _dragHovering = true),
        onDragExited: (_) => setState(() => _dragHovering = false),
        onDragDone: (details) async {
          setState(() => _dragHovering = false);
          final files = <KnowledgeImportFile>[
            for (final file in details.files)
              if (file.path.trim().isNotEmpty)
                KnowledgeImportFile(path: file.path, name: file.name),
          ];
          await _handleDrop(files);
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            body,
            if (_dragHovering)
              IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.06),
                    border: Border.all(color: cs.primary, width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: cs.surface.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: cs.primary.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Text(
                      l10n.knowledgeDropToImport,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: AppFontWeights.semibold,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DesktopBaseTile extends StatelessWidget {
  const _DesktopBaseTile({
    required this.base,
    required this.stats,
    required this.selected,
    required this.onOpen,
    required this.onDelete,
  });

  final KnowledgeBase base;
  final KnowledgeBaseStats stats;
  final bool selected;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.read<KnowledgeProvider>();

    Future<void> edit() async {
      Haptics.light();
      final draft = await showKnowledgeBaseEditor(
        context,
        itemId: base.id,
        name: base.name,
        description: base.description,
        chunkSize: base.chunkSize,
        chunkOverlap: base.chunkOverlap,
        activeAssistantIdsFor: provider.activeBaseIdsFor,
      );
      if (draft == null) return;
      await provider.updateBase(
        base.copyWith(
          name: draft.name,
          description: draft.description,
          chunkSize: draft.chunkSize,
          chunkOverlap: draft.chunkOverlap,
        ),
      );
      if (!context.mounted) return;
      await applyKnowledgeBaseBindings(
        context,
        itemId: base.id,
        selectedAssistantIds: draft.selectedAssistantIds,
      );
    }

    final content = Container(
      decoration: BoxDecoration(
        color: selected
            ? cs.primary.withValues(alpha: 0.12)
            : context.appColors.surfaceFill,
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  base.name.trim().isEmpty ? l10n.knowledgeUnnamed : base.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: AppFontWeights.medium,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Wrap(
                  spacing: 6,
                  runSpacing: 3,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      l10n.knowledgeDocsAndChunks(
                        stats.documents,
                        stats.chunks,
                      ),
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    if (!provider.isBaseBoundToAnyAssistant(base.id))
                      const KnowledgeUnboundChip(),
                  ],
                ),
              ],
            ),
          ),
          IosSwitch(
            value: base.enabled,
            width: 40,
            height: 24,
            onChanged: (value) {
              Haptics.light();
              provider.updateBase(base.copyWith(enabled: value));
            },
          ),
          IosIconButton(
            icon: Lucide.Pencil,
            size: 16,
            minSize: 32,
            semanticLabel: l10n.knowledgeEditTitle,
            onTap: edit,
          ),
          IosIconButton(
            icon: Lucide.Trash2,
            size: 16,
            minSize: 32,
            semanticLabel: l10n.knowledgeDelete,
            onTap: onDelete,
          ),
        ],
      ),
    );

    return IosCardPress(onTap: onOpen, child: content);
  }
}
