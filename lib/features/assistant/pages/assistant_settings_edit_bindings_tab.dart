part of 'assistant_settings_edit_page.dart';

/// Assistant-level bind surfaces for world books and instruction injections.
///
/// Mirrors the `_SkillsTab` structure: inline sections with a master
/// enable-all row, collapsible groups, and switch rows — no modal sheet.
class _BindingsTab extends StatefulWidget {
  const _BindingsTab({required this.assistantId});
  final String assistantId;

  @override
  State<_BindingsTab> createState() => _BindingsTabState();
}

class _BindingsTabState extends State<_BindingsTab>
    with CollapsibleGroupsMixin<_BindingsTab> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final wb = context.read<WorldBookProvider>();
      final ii = context.read<QuickInstructionProvider>();
      await wb.initialize();
      await ii.initialize();
    });
  }

  String _wbGroupKey(String groupName) => 'wb:${groupName.trim()}';
  String _iiGroupKey(String groupName) => 'ii:${groupName.trim()}';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final assistant = context.watch<AssistantProvider>().getById(
      widget.assistantId,
    );
    if (assistant == null) return const SizedBox.shrink();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      children: [
        _buildWorldBookSection(context, l10n),
        const SizedBox(height: 14),
        _buildInjectionSection(context, l10n),
      ],
    );
  }

  Widget _buildWorldBookSection(BuildContext context, AppLocalizations l10n) {
    final provider = context.watch<WorldBookProvider>();
    final books = provider.books;
    final activeIds = provider.activeBookIdsFor(widget.assistantId).toSet();

    final Map<String, List<WorldBook>> grouped = <String, List<WorldBook>>{};
    for (final book in books) {
      final g = book.group.trim();
      (grouped[g] ??= <WorldBook>[]).add(book);
    }
    final groupNames = grouped.keys.toList()
      ..sort((a, b) {
        if (a.isEmpty && b.isNotEmpty) return -1;
        if (a.isNotEmpty && b.isEmpty) return 1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    final enabledBooks = books.where((b) => b.enabled).toList(growable: false);
    final boundEnabledCount = enabledBooks
        .where((b) => activeIds.contains(b.id))
        .length;

    return _iosSectionCard(
      children: [
        _BindSectionHeader(icon: Lucide.BookOpen, title: l10n.worldBookTitle),
        _iosDivider(context),
        if (enabledBooks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: Text(
              l10n.worldBookEmptyMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          )
        else ...[
          _BindMasterRow(
            enabledCount: boundEnabledCount,
            total: enabledBooks.length,
            allEnabled: boundEnabledCount == enabledBooks.length,
            onChanged: (value) {
              final ids = value
                  ? enabledBooks.map((b) => b.id).toSet()
                  : <String>{};
              context.read<WorldBookProvider>().setActiveBookIds(
                ids.toList(growable: false),
                assistantId: widget.assistantId,
              );
            },
          ),
          _iosDivider(context),
          for (final groupName in groupNames) ...[
            CollapsibleGroupHeader(
              groupName: groupName.trim().isEmpty
                  ? l10n.worldBookUngroupedGroup
                  : groupName.trim(),
              skillCount: grouped[groupName]!.length,
              expanded: isGroupExpanded(_wbGroupKey(groupName)),
              onTap: () => toggleGroup(_wbGroupKey(groupName)),
              fontWeight: AppFontWeights.emphasis,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            ),
            CollapsibleGroupBody(
              expanded: isGroupExpanded(_wbGroupKey(groupName)),
              child: Column(
                children: [
                  for (int i = 0; i < grouped[groupName]!.length; i++) ...[
                    if (i > 0) _iosDivider(context),
                    _BindSwitchRow(
                      icon: Lucide.BookOpen,
                      title: grouped[groupName]![i].name.trim().isEmpty
                          ? l10n.worldBookUnnamed
                          : grouped[groupName]![i].name.trim(),
                      subtitle: grouped[groupName]![i].description.trim(),
                      value: activeIds.contains(grouped[groupName]![i].id),
                      onChanged: grouped[groupName]![i].enabled
                          ? (value) {
                              context
                                  .read<WorldBookProvider>()
                                  .toggleActiveBookId(
                                    grouped[groupName]![i].id,
                                    assistantId: widget.assistantId,
                                  );
                            }
                          : null,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildInjectionSection(BuildContext context, AppLocalizations l10n) {
    final provider = context.watch<QuickInstructionProvider>();
    final items = provider.systemItems;
    final activeIds = provider.activeIdsFor(widget.assistantId).toSet();

    final Map<String, List<QuickInstruction>> grouped =
        <String, List<QuickInstruction>>{};
    for (final item in items) {
      final g = item.group.trim();
      (grouped[g] ??= <QuickInstruction>[]).add(item);
    }
    final groupNames = grouped.keys.toList()
      ..sort((a, b) {
        if (a.isEmpty && b.isNotEmpty) return -1;
        if (a.isNotEmpty && b.isEmpty) return 1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    final boundCount = items.where((i) => activeIds.contains(i.id)).length;

    return _iosSectionCard(
      children: [
        _BindSectionHeader(
          icon: Lucide.Zap,
          title: l10n.instructionInjectionTitle,
        ),
        _iosDivider(context),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: Text(
              l10n.instructionInjectionEmptyMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          )
        else ...[
          _BindMasterRow(
            enabledCount: boundCount,
            total: items.length,
            allEnabled: boundCount == items.length,
            onChanged: (value) {
              final ids = value ? items.map((i) => i.id).toSet() : <String>{};
              context.read<QuickInstructionProvider>().setActiveIds(
                ids.toList(growable: false),
                assistantId: widget.assistantId,
              );
            },
          ),
          _iosDivider(context),
          for (final groupName in groupNames) ...[
            CollapsibleGroupHeader(
              groupName: groupName.trim().isEmpty
                  ? l10n.instructionInjectionUngroupedGroup
                  : groupName.trim(),
              skillCount: grouped[groupName]!.length,
              expanded: isGroupExpanded(_iiGroupKey(groupName)),
              onTap: () => toggleGroup(_iiGroupKey(groupName)),
              fontWeight: AppFontWeights.emphasis,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            ),
            CollapsibleGroupBody(
              expanded: isGroupExpanded(_iiGroupKey(groupName)),
              child: Column(
                children: [
                  for (int i = 0; i < grouped[groupName]!.length; i++) ...[
                    if (i > 0) _iosDivider(context),
                    _BindSwitchRow(
                      icon: Lucide.Zap,
                      title: grouped[groupName]![i].title.trim().isEmpty
                          ? l10n.instructionInjectionDefaultTitle
                          : grouped[groupName]![i].title.trim(),
                      value: activeIds.contains(grouped[groupName]![i].id),
                      onChanged: (value) {
                        context.read<QuickInstructionProvider>().toggleActiveId(
                          grouped[groupName]![i].id,
                          assistantId: widget.assistantId,
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class _BindSectionHeader extends StatelessWidget {
  const _BindSectionHeader({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: AppFontWeights.emphasis,
              color: cs.onSurface.withValues(alpha: 0.9),
            ),
          ),
        ],
      ),
    );
  }
}

class _BindMasterRow extends StatelessWidget {
  const _BindMasterRow({
    required this.enabledCount,
    required this.total,
    required this.allEnabled,
    required this.onChanged,
  });

  final int enabledCount;
  final int total;
  final bool allEnabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return _TactileRow(
      onTap: () => onChanged(!allEnabled),
      builder: (pressed) {
        final baseColor = cs.onSurface.withValues(alpha: 0.9);
        return _AnimatedPressColor(
          pressed: pressed,
          base: baseColor,
          builder: (color) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 36,
                    child: Icon(Lucide.Sparkles, size: 20, color: color),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.skillsEnableAll,
                          style: TextStyle(fontSize: 15, color: color),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          l10n.skillsEnabledCount(enabledCount, total),
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IosSwitch(value: allEnabled, onChanged: onChanged),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _BindSwitchRow extends StatelessWidget {
  const _BindSwitchRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final alpha = onChanged == null ? 0.55 : 0.9;

    Widget row(Color color) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 36,
              child: Icon(icon, size: 20, color: value ? cs.primary : color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: AppFontWeights.semibold,
                      color: color,
                    ),
                  ),
                  if ((subtitle ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle!.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.25,
                        color: cs.onSurface.withValues(alpha: 0.62 * alpha),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            IosSwitch(
              value: value,
              onChanged: onChanged == null ? null : (v) => onChanged!(v),
            ),
          ],
        ),
      );
    }

    return _TactileRow(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      haptics: false,
      builder: (pressed) {
        final baseColor = cs.onSurface.withValues(alpha: alpha);
        return _AnimatedPressColor(
          pressed: pressed,
          base: baseColor,
          builder: (color) => row(color),
        );
      },
    );
  }
}
