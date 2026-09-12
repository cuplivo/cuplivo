import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/knowledge.dart';
import '../../../core/providers/knowledge_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/assistant_bind_multi_select.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import '../widgets/knowledge_base_editor.dart';
import '../widgets/knowledge_unbound_chip.dart';
import 'knowledge_base_detail_page.dart';

class KnowledgePage extends StatefulWidget {
  const KnowledgePage({super.key});

  @override
  State<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends State<KnowledgePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await context.read<KnowledgeProvider>().initialize();
    });
  }

  Future<void> _create() async {
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
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.watch<KnowledgeProvider>();
    final bases = provider.bases;

    return Scaffold(
      appBar: AppBar(
        leading: IosIconButton(
          icon: Lucide.ArrowLeft,
          minSize: 44,
          size: 22,
          semanticLabel: l10n.settingsPageBackButton,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.knowledgePageTitle),
        actions: [
          IosIconButton(
            icon: Lucide.Plus,
            minSize: 44,
            size: 22,
            semanticLabel: l10n.knowledgeAdd,
            onTap: () async {
              Haptics.light();
              await _create();
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: bases.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Lucide.BookOpenText,
                    size: 64,
                    color: cs.onSurface.withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.knowledgePageEmpty,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.6),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
              children: [
                for (final base in bases)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: KnowledgeBaseCard(
                      base: base,
                      stats: provider.statsForSync(base.id),
                      onOpen: () {
                        Haptics.light();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                KnowledgeBaseDetailPage(baseId: base.id),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Base summary card. Shared with the desktop pane so both surfaces render the
/// same layout.
class KnowledgeBaseCard extends StatelessWidget {
  const KnowledgeBaseCard({
    super.key,
    required this.base,
    required this.stats,
    this.onOpen,
  });

  final KnowledgeBase base;
  final KnowledgeBaseStats stats;
  final VoidCallback? onOpen;

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

    Future<void> remove() async {
      Haptics.light();
      final confirmed = await confirmKnowledgeAction(
        context,
        title: l10n.knowledgeDeleteTitle,
        message: l10n.knowledgeDeleteMessage(
          base.name.trim().isEmpty ? l10n.knowledgeUnnamed : base.name,
        ),
        confirmLabel: l10n.knowledgeDelete,
      );
      if (!confirmed) return;
      await provider.deleteBase(base.id);
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        message: l10n.knowledgeDeleted(base.name),
        type: NotificationType.success,
      );
    }

    final indicator = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        l10n.knowledgeDocsAndChunks(stats.documents, stats.chunks),
        style: TextStyle(
          fontSize: 12,
          fontWeight: AppFontWeights.medium,
          color: cs.primary,
        ),
      ),
    );
    final isUnbound = !provider.isBaseBoundToAnyAssistant(base.id);

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            Lucide.BookOpenText,
            size: 22,
            color: cs.onSurface.withValues(alpha: 0.75),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  base.name.trim().isEmpty ? l10n.knowledgeUnnamed : base.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.semibold,
                    color: cs.onSurface,
                  ),
                ),
                if (base.description.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    base.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    indicator,
                    if (isUnbound) const KnowledgeUnboundChip(),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          IosSwitch(
            value: base.enabled,
            onChanged: (value) {
              Haptics.light();
              provider.updateBase(base.copyWith(enabled: value));
            },
          ),
          IosIconButton(
            icon: Lucide.Pencil,
            size: 18,
            minSize: 36,
            semanticLabel: l10n.knowledgeEditTitle,
            onTap: edit,
          ),
          IosIconButton(
            icon: Lucide.Trash2,
            size: 18,
            minSize: 36,
            semanticLabel: l10n.knowledgeDelete,
            onTap: remove,
          ),
        ],
      ),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.appColors.surfaceFill,
        borderRadius: BorderRadius.circular(14),
      ),
      child: onOpen == null
          ? content
          : IosCardPress(onTap: onOpen!, child: content),
    );
  }
}
