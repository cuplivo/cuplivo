import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/quick_instruction.dart';
import '../../../core/providers/instruction_injection_group_provider.dart';
import '../../../core/providers/quick_instruction_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../../instruction_injection/pages/instruction_injection_page.dart';

class InstructionInjectionSheet extends StatefulWidget {
  const InstructionInjectionSheet({
    super.key,
    required this.assistantId,
    required this.conversationId,
    required this.selectedInvocationIds,
    required this.onToggleInvocation,
    this.editingUserMessage = false,
  });

  final String? assistantId;
  final String? conversationId;
  final Set<String> selectedInvocationIds;
  final ValueChanged<QuickInstructionInvocationSnapshot> onToggleInvocation;
  final bool editingUserMessage;

  @override
  State<InstructionInjectionSheet> createState() =>
      _InstructionInjectionSheetState();
}

class _InstructionInjectionSheetState extends State<InstructionInjectionSheet> {
  late final Set<String> _selectedInvocationIds = widget.selectedInvocationIds
      .toSet();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      top: false,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.58,
        maxChildSize: 0.88,
        minChildSize: 0.42,
        builder: (sheetContext, scrollController) {
          final provider = sheetContext.watch<QuickInstructionProvider>();
          final groupUi = sheetContext
              .watch<InstructionInjectionGroupProvider>();
          final activeSystemIds = provider
              .activeIdsFor(widget.assistantId)
              .toSet();
          final activePersistentIds = provider
              .persistentIdsFor(widget.conversationId)
              .toSet();
          final grouped = <String, List<QuickInstruction>>{};
          for (final item in provider.items) {
            (grouped[item.group.trim()] ??= <QuickInstruction>[]).add(item);
          }

          return Column(
            children: [
              _SheetTopBar(
                title: l10n.instructionInjectionTitle,
                onClose: () => Navigator.of(sheetContext).maybePop(),
                onManage: () {
                  Navigator.of(sheetContext).maybePop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const InstructionInjectionPage(),
                    ),
                  );
                },
              ),
              Expanded(
                child: provider.items.isEmpty
                    ? _EmptyState(
                        onManage: () {
                          Navigator.of(sheetContext).maybePop();
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const InstructionInjectionPage(),
                            ),
                          );
                        },
                      )
                    : ListView(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                        children: [
                          for (final entry in grouped.entries) ...[
                            _GroupHeader(
                              title: entry.key.isEmpty
                                  ? l10n.instructionInjectionUngroupedGroup
                                  : entry.key,
                              collapsed: groupUi.isCollapsed(entry.key),
                              onToggle: () => sheetContext
                                  .read<InstructionInjectionGroupProvider>()
                                  .toggleCollapsed(entry.key),
                            ),
                            if (!groupUi.isCollapsed(entry.key))
                              for (final item in entry.value)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: _QuickInstructionRow(
                                    item: item,
                                    subtitle: _placementLabel(l10n, item),
                                    active: item.isSystem
                                        ? activeSystemIds.contains(item.id)
                                        : item.isPersistent &&
                                              !widget.editingUserMessage
                                        ? activePersistentIds.contains(item.id)
                                        : _selectedInvocationIds.contains(
                                            item.id,
                                          ),
                                    onTap: () async {
                                      Haptics.light();
                                      if (item.isInputBox) {
                                        Navigator.of(sheetContext).pop(item);
                                        return;
                                      }
                                      final current = sheetContext
                                          .read<QuickInstructionProvider>();
                                      if (item.isSystem) {
                                        await current.toggleActiveId(
                                          item.id,
                                          assistantId: widget.assistantId,
                                        );
                                        return;
                                      }
                                      if (item.isPersistent &&
                                          !widget.editingUserMessage) {
                                        final id = widget.conversationId;
                                        if (id != null) {
                                          await current.togglePersistent(
                                            item.id,
                                            conversationId: id,
                                          );
                                        }
                                        return;
                                      }
                                      final snapshot =
                                          QuickInstructionInvocationSnapshot.fromInstruction(
                                            item,
                                            order: provider.items.indexWhere(
                                              (candidate) =>
                                                  candidate.id == item.id,
                                            ),
                                          );
                                      setState(() {
                                        if (!_selectedInvocationIds.add(
                                          item.id,
                                        )) {
                                          _selectedInvocationIds.remove(
                                            item.id,
                                          );
                                        }
                                      });
                                      widget.onToggleInvocation(snapshot);
                                    },
                                  ),
                                ),
                          ],
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SheetTopBar extends StatelessWidget {
  const _SheetTopBar({
    required this.title,
    required this.onClose,
    required this.onManage,
  });

  final String title;
  final VoidCallback onClose;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            IosIconButton(
              icon: Lucide.X,
              size: 20,
              color: cs.onSurface,
              onTap: onClose,
            ),
            Expanded(
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: AppFontWeights.emphasis,
                ),
              ),
            ),
            IosIconButton(
              icon: Lucide.Settings2,
              size: 20,
              color: cs.onSurface,
              onTap: onManage,
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.collapsed,
    required this.onToggle,
  });

  final String title;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IosCardPress(
      haptics: false,
      baseColor: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      onTap: onToggle,
      child: Row(
        children: [
          AnimatedRotation(
            turns: collapsed ? 0 : 0.25,
            duration: const Duration(milliseconds: 200),
            child: Icon(
              Lucide.ChevronRight,
              size: 16,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: AppFontWeights.emphasis,
                color: cs.onSurface.withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickInstructionRow extends StatelessWidget {
  const _QuickInstructionRow({
    required this.item,
    required this.subtitle,
    required this.active,
    required this.onTap,
  });

  final QuickInstruction item;
  final String subtitle;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IosCardPress(
      baseColor: cs.surface,
      borderRadius: BorderRadius.circular(14),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      onTap: onTap,
      child: Row(
        children: [
          Icon(Lucide.Zap, size: 19, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: AppFontWeights.medium),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.56),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (item.isInputBox)
            Icon(
              Lucide.ChevronRight,
              size: 18,
              color: cs.onSurface.withValues(alpha: 0.45),
            )
          else
            IgnorePointer(
              child: IosSwitch(value: active, onChanged: (_) {}),
            ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onManage});

  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Lucide.Zap,
              size: 48,
              color: cs.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 12),
            Text(l10n.instructionInjectionEmptyMessage),
            const SizedBox(height: 14),
            IosCardPress(
              baseColor: cs.primaryContainer,
              borderRadius: BorderRadius.circular(12),
              onTap: onManage,
              child: Text(
                l10n.quickInstructionManageButton,
                style: TextStyle(color: cs.onPrimaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _placementLabel(AppLocalizations l10n, QuickInstruction item) {
  return switch (item.placement) {
    QuickInstructionPlacement.systemPrompt =>
      l10n.quickInstructionPlacementSystem,
    QuickInstructionPlacement.beforeUserMessage =>
      item.isPersistent
          ? l10n.quickInstructionPlacementBeforePersistent
          : l10n.quickInstructionPlacementBeforeOneShot,
    QuickInstructionPlacement.afterUserMessage =>
      item.isPersistent
          ? l10n.quickInstructionPlacementAfterPersistent
          : l10n.quickInstructionPlacementAfterOneShot,
    QuickInstructionPlacement.inputBox =>
      l10n.quickInstructionPlacementInputBox,
  };
}

Future<QuickInstruction?> showInstructionInjectionSheet(
  BuildContext context, {
  required String? assistantId,
  required String? conversationId,
  required Set<String> selectedInvocationIds,
  required ValueChanged<QuickInstructionInvocationSnapshot> onToggleInvocation,
  bool editingUserMessage = false,
}) {
  final cs = Theme.of(context).colorScheme;
  return showModalBottomSheet<QuickInstruction>(
    context: context,
    isScrollControlled: true,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => InstructionInjectionSheet(
      assistantId: assistantId,
      conversationId: conversationId,
      selectedInvocationIds: selectedInvocationIds,
      onToggleInvocation: onToggleInvocation,
      editingUserMessage: editingUserMessage,
    ),
  );
}
