part of 'assistant_settings_edit_page.dart';

/// Assistant-level Knowledge Base binding (issue #389): which bound bases this
/// assistant may retrieve from, plus the max-injected-chunks knob. Mirrors the
/// `_BindingsTab` section pattern.
class _KnowledgeTab extends StatefulWidget {
  const _KnowledgeTab({required this.assistantId});

  final String assistantId;

  @override
  State<_KnowledgeTab> createState() => _KnowledgeTabState();
}

class _KnowledgeTabState extends State<_KnowledgeTab> {
  late final TextEditingController _topKController;
  late final FocusNode _topKFocus;

  @override
  void initState() {
    super.initState();
    _topKController = TextEditingController(
      text: '${KnowledgeStore.defaultTopK}',
    );
    _topKFocus = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final provider = context.read<KnowledgeProvider>();
      await provider.initialize();
      if (!mounted) return;
      _topKController.text = '${provider.topKFor(widget.assistantId)}';
    });
  }

  @override
  void dispose() {
    _topKController.dispose();
    _topKFocus.dispose();
    super.dispose();
  }

  Future<void> _commitTopK() async {
    final parsed = int.tryParse(_topKController.text.trim());
    final value = parsed == null || parsed < 1
        ? KnowledgeStore.defaultTopK
        : parsed;
    _topKController.text = '$value';
    await context.read<KnowledgeProvider>().setTopK(
      value,
      assistantId: widget.assistantId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.watch<KnowledgeProvider>();
    final enabledBases = provider.bases
        .where((base) => base.enabled)
        .toList(growable: false);
    final activeIds = provider.activeBaseIdsFor(widget.assistantId).toSet();
    final boundCount = enabledBases
        .where((base) => activeIds.contains(base.id))
        .length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      children: [
        _iosSectionCard(
          children: [
            _BindSectionHeader(
              icon: Lucide.BookOpenText,
              title: l10n.knowledgePageTitle,
            ),
            _iosDivider(context),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.knowledgeTabTopKLabel,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: AppFontWeights.semibold,
                        color: cs.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  IosNumberField(
                    controller: _topKController,
                    focusNode: _topKFocus,
                    labelWidth: 0,
                    onCommit: _commitTopK,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _iosSectionCard(
          children: [
            _BindSectionHeader(
              icon: Lucide.FileText,
              title: l10n.knowledgeTabBasesTitle,
            ),
            _iosDivider(context),
            if (enabledBases.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 20,
                ),
                child: Text(
                  l10n.knowledgePageEmpty,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: cs.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              )
            else ...[
              _BindMasterRow(
                enabledCount: boundCount,
                total: enabledBases.length,
                allEnabled: boundCount == enabledBases.length,
                onChanged: (value) {
                  final ids = value
                      ? enabledBases.map((base) => base.id).toList()
                      : const <String>[];
                  provider.setActiveBaseIds(
                    ids,
                    assistantId: widget.assistantId,
                  );
                },
              ),
              _iosDivider(context),
              for (int i = 0; i < enabledBases.length; i++) ...[
                if (i > 0) _iosDivider(context),
                _BindSwitchRow(
                  icon: Lucide.BookOpenText,
                  title: enabledBases[i].name.trim().isEmpty
                      ? l10n.knowledgeUnnamed
                      : enabledBases[i].name.trim(),
                  subtitle: enabledBases[i].description.trim(),
                  value: activeIds.contains(enabledBases[i].id),
                  onChanged: (value) {
                    final ids = activeIds.toSet();
                    if (value) {
                      ids.add(enabledBases[i].id);
                    } else {
                      ids.remove(enabledBases[i].id);
                    }
                    provider.setActiveBaseIds(
                      ids.toList(growable: false),
                      assistantId: widget.assistantId,
                    );
                  },
                ),
              ],
            ],
          ],
        ),
      ],
    );
  }
}
