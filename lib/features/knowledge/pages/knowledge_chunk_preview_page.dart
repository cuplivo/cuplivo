import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/knowledge.dart';
import '../../../core/providers/knowledge_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';

/// Read-only chunk listing for one document (preview / acceptance surface).
class KnowledgeChunkPreviewPage extends StatefulWidget {
  const KnowledgeChunkPreviewPage({super.key, required this.document});

  final KnowledgeDocument document;

  @override
  State<KnowledgeChunkPreviewPage> createState() =>
      _KnowledgeChunkPreviewPageState();
}

class _KnowledgeChunkPreviewPageState extends State<KnowledgeChunkPreviewPage> {
  List<KnowledgeChunk>? _chunks;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final chunks = await context.read<KnowledgeProvider>().chunksForDocument(
        widget.document.id,
      );
      if (!mounted) return;
      setState(() => _chunks = chunks);
    } catch (e) {
      debugPrint('KnowledgeChunkPreviewPage: failed to load chunks: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final chunks = _chunks;

    return Scaffold(
      appBar: AppBar(
        leading: IosIconButton(
          icon: Lucide.ArrowLeft,
          minSize: 44,
          size: 22,
          semanticLabel: l10n.settingsPageBackButton,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          widget.document.name.trim().isEmpty
              ? l10n.knowledgeUnnamed
              : widget.document.name,
        ),
      ),
      body: chunks == null
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
              itemCount: chunks.length,
              itemBuilder: (context, index) {
                final chunk = chunks[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.appColors.surfaceFill,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
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
                          const SizedBox(height: 8),
                          Text(
                            chunk.content,
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.4,
                              color: cs.onSurface.withValues(alpha: 0.9),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
