import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/knowledge.dart';
import '../../../core/providers/knowledge_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../core/services/knowledge/knowledge_import_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/assistant_bind_multi_select.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import 'knowledge_base_editor.dart';
import 'knowledge_import_result_dialog.dart';

/// Document manager for one knowledge base (issue #389). Shared by the mobile
/// detail page and the desktop settings pane so both surfaces stay in sync.
class KnowledgeDocumentList extends StatefulWidget {
  const KnowledgeDocumentList({
    super.key,
    required this.baseId,
    this.onOpenDocument,
  });

  final String baseId;

  /// Platform hook: mobile pushes a preview page, desktop opens a dialog.
  final void Function(KnowledgeDocument document)? onOpenDocument;

  @override
  State<KnowledgeDocumentList> createState() => _KnowledgeDocumentListState();
}

class _KnowledgeDocumentListState extends State<KnowledgeDocumentList> {
  List<KnowledgeDocument>? _documents;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void didUpdateWidget(covariant KnowledgeDocumentList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.baseId != widget.baseId) {
      _reload();
    }
  }

  Future<void> _reload() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final documents = await context.read<KnowledgeProvider>().documents(
        widget.baseId,
      );
      if (!mounted) return;
      setState(() {
        _documents = documents;
        _loading = false;
      });
    } catch (e) {
      debugPrint('KnowledgeDocumentList: failed to load documents: $e');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _import() async {
    final provider = context.read<KnowledgeProvider>();
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: KnowledgeImportService.acceptedExtensions,
      );
    } catch (e) {
      debugPrint('KnowledgeDocumentList: file picker failed: $e');
      return;
    }
    if (result == null || result.files.isEmpty) return;

    final files = <KnowledgeImportFile>[];
    for (final file in result.files) {
      final path = file.path;
      if (path == null || path.isEmpty) continue;
      files.add(KnowledgeImportFile(path: path, name: file.name));
    }
    if (files.isEmpty) return;

    final results = await provider.importFiles(widget.baseId, files);
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    showKnowledgeImportResult(context, results);
  }

  Future<void> _editSettings() async {
    final provider = context.read<KnowledgeProvider>();
    final base = provider.getById(widget.baseId);
    if (base == null) return;
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
    if (draft == null || !mounted) return;
    await provider.updateBase(
      base.copyWith(
        name: draft.name,
        description: draft.description,
        chunkSize: draft.chunkSize,
        chunkOverlap: draft.chunkOverlap,
      ),
    );
    if (!mounted) return;
    await applyKnowledgeBaseBindings(
      context,
      itemId: base.id,
      selectedAssistantIds: draft.selectedAssistantIds,
    );
    if (!mounted) return;
    await _reload();
  }

  Future<void> _deleteDocument(KnowledgeDocument document) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await confirmKnowledgeAction(
      context,
      title: l10n.knowledgeDeleteDocumentTitle,
      message: l10n.knowledgeDeleteDocumentMessage(
        document.name.trim().isEmpty ? l10n.knowledgeUnnamed : document.name,
      ),
      confirmLabel: l10n.knowledgeDelete,
    );
    if (!confirmed || !mounted) return;
    await context.read<KnowledgeProvider>().deleteDocument(document.id);
    if (!mounted) return;
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<KnowledgeProvider>();
    final documents = _documents ?? const <KnowledgeDocument>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Text(
                l10n.knowledgeDocCount(documents.length),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: AppFontWeights.semibold,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              const Spacer(),
              IosIconButton(
                icon: Lucide.Settings2,
                size: 20,
                minSize: 40,
                semanticLabel: l10n.knowledgeSettingsTitle,
                onTap: _editSettings,
              ),
              IosIconButton(
                icon: Lucide.cloudDownload,
                size: 20,
                minSize: 40,
                semanticLabel: l10n.knowledgeAddDocuments,
                enabled: !provider.importing,
                onTap: () async {
                  Haptics.light();
                  await _import();
                },
              ),
            ],
          ),
        ),
        if (provider.importing)
          _StatusRow(
            label: l10n.knowledgeImporting(
              provider.importCompleted,
              provider.importTotal,
              provider.importCurrentName ?? '',
            ),
          ),
        if (provider.rebuilding) _StatusRow(label: l10n.knowledgeRebuilding),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (documents.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Center(
              child: Text(
                l10n.knowledgeNoDocuments,
                style: TextStyle(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.55),
                  fontSize: 14,
                ),
              ),
            ),
          )
        else
          for (final document in documents)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: _DocumentRow(
                document: document,
                onTap: widget.onOpenDocument == null
                    ? null
                    : () {
                        Haptics.light();
                        widget.onOpenDocument!(document);
                      },
                onDelete: () => _deleteDocument(document),
              ),
            ),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DocumentRow extends StatelessWidget {
  const _DocumentRow({
    required this.document,
    required this.onDelete,
    this.onTap,
  });

  final KnowledgeDocument document;
  final VoidCallback onDelete;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(
            Lucide.FileText,
            size: 20,
            color: cs.onSurface.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  document.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.medium,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.knowledgeDocStats(
                    document.charCount,
                    document.chunkTotal,
                  ),
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          IosIconButton(
            icon: Lucide.Trash2,
            size: 18,
            minSize: 36,
            semanticLabel: l10n.knowledgeDelete,
            onTap: () {
              Haptics.light();
              onDelete();
            },
          ),
        ],
      ),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.appColors.surfaceFill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: onTap == null
          ? content
          : IosCardPress(onTap: onTap!, child: content),
    );
  }
}
