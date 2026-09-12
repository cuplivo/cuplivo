import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/knowledge_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../widgets/knowledge_document_list.dart';
import 'knowledge_chunk_preview_page.dart';

class KnowledgeBaseDetailPage extends StatefulWidget {
  const KnowledgeBaseDetailPage({super.key, required this.baseId});

  final String baseId;

  @override
  State<KnowledgeBaseDetailPage> createState() =>
      _KnowledgeBaseDetailPageState();
}

class _KnowledgeBaseDetailPageState extends State<KnowledgeBaseDetailPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await context.read<KnowledgeProvider>().initialize();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final base = context.watch<KnowledgeProvider>().getById(widget.baseId);

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
          (base?.name.trim().isEmpty ?? true)
              ? l10n.knowledgeUnnamed
              : base!.name,
        ),
      ),
      body: base == null
          ? Center(child: Text(l10n.knowledgePageEmpty))
          : SingleChildScrollView(
              child: KnowledgeDocumentList(
                baseId: widget.baseId,
                onOpenDocument: (document) {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          KnowledgeChunkPreviewPage(document: document),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
