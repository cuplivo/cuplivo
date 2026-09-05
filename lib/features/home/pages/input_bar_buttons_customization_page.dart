import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../shared/responsive/breakpoints.dart';
import '../utils/input_bar_button_layout.dart';

/// Mobile full-page editing surface for input bar buttons (order + direct /
/// in-more), mirroring the assistant tab layout page.
class InputBarButtonsCustomizationPage extends StatelessWidget {
  const InputBarButtonsCustomizationPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            minSize: 44,
            semanticLabel: l10n.settingsPageBackButton,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.chatInputBarCustomizeTitle),
        actions: [
          Tooltip(
            message: l10n.chatInputBarCustomizeResetTooltip,
            child: IosIconButton(
              icon: Lucide.RotateCcw,
              color: cs.onSurface,
              size: 20,
              minSize: 44,
              semanticLabel: l10n.chatInputBarCustomizeResetTooltip,
              onTap: () =>
                  context.read<SettingsProvider>().resetChatInputButtons(),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: const InputBarButtonsCustomizationContent(),
    );
  }
}

/// Desktop centered-dialog shell (assistant-edit-parity).
Future<void> showInputBarButtonsCustomizationDialog(
  BuildContext context,
) async {
  final l10n = AppLocalizations.of(context)!;
  final cs = Theme.of(context).colorScheme;
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'input-bar-buttons-customize',
    barrierColor: cs.scrim.withValues(alpha: 0.25),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (ctx, _, __) {
      final dialog = Material(
        color: Colors.transparent,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: cs.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: Theme.of(ctx).brightness == Brightness.dark
                        ? cs.onSurface.withValues(alpha: 0.08)
                        : cs.outlineVariant.withValues(alpha: 0.25),
                  ),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 44,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.chatInputBarCustomizeTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: AppFontWeights.emphasis,
                              ),
                            ),
                          ),
                          Tooltip(
                            message: l10n.chatInputBarCustomizeResetTooltip,
                            child: IconButton(
                              tooltip: l10n.chatInputBarCustomizeResetTooltip,
                              icon: const Icon(Lucide.RotateCcw, size: 16),
                              color: cs.onSurface,
                              onPressed: () => context
                                  .read<SettingsProvider>()
                                  .resetChatInputButtons(),
                            ),
                          ),
                          IconButton(
                            tooltip: MaterialLocalizations.of(
                              ctx,
                            ).closeButtonTooltip,
                            icon: const Icon(Lucide.X, size: 18),
                            color: cs.onSurface,
                            onPressed: () => Navigator.of(ctx).maybePop(),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Divider(
                    height: 1,
                    thickness: 0.5,
                    color: cs.outlineVariant.withValues(alpha: 0.12),
                  ),
                  const Expanded(child: InputBarButtonsCustomizationContent()),
                ],
              ),
            ),
          ),
        ),
      );
      return dialog;
    },
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.98, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// Shared editing body: explanatory subtitle + reorderable rows with a direct
/// visibility switch. Drag = the grip handle only (tap-safe switches).
class InputBarButtonsCustomizationContent extends StatelessWidget {
  const InputBarButtonsCustomizationContent({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsProvider>();
    // Boot from the resolved layout (single source of truth): while the user
    // never customized, the switches reflect the platform's effective
    // placement — e.g. the customize entry is OFF (in the More bucket) by
    // default on every platform. A first toggle/reorder persists the resolved
    // state explicitly.
    final resolved = resolveInputBarButtonLayout(
      savedOrder: settings.chatInputButtonOrder,
      savedMoreIds: settings.chatInputMoreButtonIds,
      tabletLayout: MediaQuery.sizeOf(context).width >= AppBreakpoints.tablet,
    );
    final ordered = resolved.orderedIds;
    final moreIds = resolved.moreIds;
    final visibleCount = ordered.where((id) => !moreIds.contains(id)).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Text(
            l10n.chatInputBarCustomizeSubtitle,
            style: TextStyle(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.68),
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 24),
            itemCount: ordered.length,
            onReorderItem: (oldIndex, newIndex) async {
              final next = ordered.toList();
              final moved = next.removeAt(oldIndex);
              next.insert(newIndex, moved);
              await context.read<SettingsProvider>().setChatInputButtonOrder(
                next,
              );
            },
            proxyDecorator: (child, index, animation) {
              return AnimatedBuilder(
                animation: animation,
                builder: (context, _) {
                  final t = Curves.easeOutCubic.transform(animation.value);
                  return Transform.scale(
                    scale: 0.98 + 0.02 * t,
                    child: Material(
                      color: Colors.transparent,
                      elevation: 0,
                      child: child,
                    ),
                  );
                },
              );
            },
            itemBuilder: (context, index) {
              final id = ordered[index];
              final visible = !moreIds.contains(id);
              return Padding(
                key: ValueKey('input-bar-button-layout-$id'),
                padding: const EdgeInsets.only(bottom: 10),
                child: _ButtonLayoutTile(
                  id: id,
                  index: index,
                  visible: visible,
                  onVisibleChanged: (nextVisible) async {
                    if (!nextVisible && visibleCount <= 1) {
                      showAppSnackBar(
                        context,
                        message: l10n.chatInputBarCustomizeAtLeastOneVisible,
                        type: NotificationType.warning,
                      );
                      return;
                    }
                    final nextMore = {...moreIds};
                    if (nextVisible) {
                      nextMore.remove(id);
                    } else {
                      nextMore.add(id);
                    }
                    await context
                        .read<SettingsProvider>()
                        .setChatInputMoreButtonIds(nextMore.toList());
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ButtonLayoutTile extends StatelessWidget {
  const _ButtonLayoutTile({
    required this.id,
    required this.index,
    required this.visible,
    required this.onVisibleChanged,
  });

  final String id;
  final int index;
  final bool visible;
  final ValueChanged<bool> onVisibleChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final bg = context.appColors.surfaceCard;
    final fg = visible
        ? cs.onSurface.withValues(alpha: 0.9)
        : cs.onSurface.withValues(alpha: 0.42);
    final spec = _specOf(id, l10n);
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.12 : 0.08),
          width: 0.8,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: [
            SizedBox(width: 34, child: Icon(spec.icon, size: 20, color: fg)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                spec.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, color: fg),
              ),
            ),
            IosSwitch(
              value: visible,
              semanticLabel: spec.label,
              onChanged: onVisibleChanged,
            ),
            // Drag zone is the grip only — never overlapping the switch.
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Icon(
                  Lucide.GripVertical,
                  size: 18,
                  color: cs.onSurface.withValues(alpha: 0.42),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ButtonSpec {
  const _ButtonSpec(this.icon, this.label);
  final IconData icon;
  final String label;
}

_ButtonSpec _specOf(String id, AppLocalizations l10n) {
  return switch (id) {
    inputBarButtonModel => _ButtonSpec(
      Lucide.Boxes,
      l10n.chatInputBarSelectModelTooltip,
    ),
    inputBarButtonSearch => _ButtonSpec(
      Lucide.Search,
      l10n.chatInputBarOnlineSearchTooltip,
    ),
    inputBarButtonReasoning => _ButtonSpec(
      Lucide.Brain,
      l10n.chatInputBarReasoningStrengthTooltip,
    ),
    inputBarButtonTools => _ButtonSpec(
      Lucide.Wrench,
      l10n.chatInputBarToolsTooltip,
    ),
    inputBarButtonQuickPhrase => _ButtonSpec(
      Lucide.Zap,
      l10n.chatInputBarQuickPhraseTooltip,
    ),
    inputBarButtonCamera => _ButtonSpec(
      Lucide.Camera,
      l10n.bottomToolsSheetCamera,
    ),
    inputBarButtonPhotos => _ButtonSpec(
      Lucide.Image,
      l10n.bottomToolsSheetPhotos,
    ),
    inputBarButtonUpload => _ButtonSpec(
      Lucide.Paperclip,
      l10n.bottomToolsSheetUpload,
    ),
    inputBarButtonWorldBook => _ButtonSpec(
      Lucide.BookOpen,
      l10n.worldBookTitle,
    ),
    inputBarButtonSkills => _ButtonSpec(Lucide.Sparkles, l10n.skillsTitle),
    inputBarButtonContext => _ButtonSpec(Lucide.Eraser, l10n.contextManagement),
    inputBarButtonMiniMap => _ButtonSpec(Lucide.Map, l10n.miniMapTooltip),
    inputBarButtonDocument => _ButtonSpec(
      Lucide.FileText,
      l10n.documentProcessingTitle,
    ),
    inputBarButtonCustomize => _ButtonSpec(
      Lucide.Settings2,
      l10n.chatInputBarCustomizeTitle,
    ),
    // Unreachable: ids are validated by orderedInputBarButtonIds.
    _ => _unknownSpec(id),
  };
}

_ButtonSpec _unknownSpec(String id) {
  assert(false, 'unknown input bar button id: $id');
  return const _ButtonSpec(Lucide.circleDot, '');
}
