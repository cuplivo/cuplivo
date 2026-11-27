import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_checkbox.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/design_tokens.dart';

class SidebarSelectionHeader extends StatelessWidget {
  const SidebarSelectionHeader({
    super.key,
    required this.selectedCount,
    required this.allSelected,
    required this.onCancel,
    required this.onToggleSelectAll,
  });

  final int selectedCount;
  final bool allSelected;
  final VoidCallback onCancel;
  final VoidCallback onToggleSelectAll;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;

    return Row(
      children: [
        IosIconButton(
          icon: Lucide.X,
          size: 22,
          minSize: 36,
          semanticLabel: l10n.sideDrawerCancel,
          onTap: onCancel,
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              final incoming =
                  animation.status != AnimationStatus.reverse &&
                  animation.status != AnimationStatus.dismissed;
              final begin = incoming
                  ? const Offset(0, 0.4)
                  : const Offset(0, -0.4);
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: begin,
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              );
            },
            child: Text(
              l10n.sideDrawerSelectionTitle(selectedCount),
              key: ValueKey<int>(selectedCount),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: AppFontWeights.semibold,
                color: cs.onSurface,
              ),
            ),
          ),
        ),
        IosCardPress(
          baseColor: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          onTap: onToggleSelectAll,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IgnorePointer(
                child: IosCheckbox(
                  value: allSelected,
                  size: 18,
                  hitTestSize: 32,
                  enableHaptics: false,
                  onChanged: (_) {},
                ),
              ),
              const SizedBox(width: 2),
              Text(
                allSelected
                    ? l10n.sideDrawerSelectionDeselectAll
                    : l10n.sideDrawerSelectionSelectAll,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: AppFontWeights.semibold,
                  color: cs.onSurface,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class SidebarSelectionActionBar extends StatelessWidget {
  const SidebarSelectionActionBar({
    super.key,
    required this.selectedCount,
    required this.allSelectedPinned,
    required this.canMove,
    required this.onPin,
    required this.onMove,
    required this.onDelete,
  });

  final int selectedCount;
  final bool allSelectedPinned;

  /// Whether the selection holds at least one conversation the move picker can
  /// actually move. A group's topics belong to the group, not to an assistant.
  final bool canMove;
  final VoidCallback onPin;
  final VoidCallback onMove;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;
    final enabled = selectedCount > 0;

    final bg = cs.surface.withValues(alpha: isDark ? 0.35 : 0.78);
    final shadowColor = cs.shadow.withValues(alpha: isDark ? 0.40 : 0.10);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        boxShadow: [
          BoxShadow(
            color: shadowColor,
            blurRadius: 22,
            offset: const Offset(0, -10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: ColoredBox(
            color: bg,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.sm,
                AppSpacing.xs,
                AppSpacing.sm,
                AppSpacing.sm,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 380;
                  return Row(
                    children: [
                      Expanded(
                        child: _SidebarSelectionActionButton(
                          icon: allSelectedPinned ? Lucide.PinOff : Lucide.Pin,
                          label: allSelectedPinned
                              ? l10n.sideDrawerSelectionUnpin
                              : l10n.sideDrawerSelectionPin,
                          color: cs.onSurface,
                          onTap: enabled ? onPin : null,
                          dense: compact,
                        ),
                      ),
                      if (canMove) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: _SidebarSelectionActionButton(
                            icon: Lucide.Shuffle,
                            label: l10n.sideDrawerSelectionMove,
                            color: cs.primary,
                            onTap: enabled ? onMove : null,
                            dense: compact,
                          ),
                        ),
                      ],
                      const SizedBox(width: 10),
                      Expanded(
                        child: _SidebarSelectionActionButton(
                          icon: Lucide.Trash2,
                          label: l10n.sideDrawerSelectionDelete,
                          color: cs.error,
                          onTap: enabled ? onDelete : null,
                          dense: compact,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarSelectionActionButton extends StatelessWidget {
  const _SidebarSelectionActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    required this.dense,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final bg = Color.alphaBlend(
      cs.onSurface.withValues(alpha: 0.04),
      color.withValues(alpha: isDark ? 0.18 : 0.14),
    );
    final content = FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: dense ? 16 : 18, color: color),
          SizedBox(width: dense ? 4 : 6),
          Text(
            label,
            style: TextStyle(
              fontSize: dense ? 13 : 14,
              fontWeight: AppFontWeights.medium,
              color: color,
            ),
          ),
        ],
      ),
    );

    return IosCardPress(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      baseColor: bg,
      pressedBlendStrength: isDark ? 0.20 : 0.16,
      pressedScale: 0.98,
      padding: dense
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 10)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: onTap == null ? Opacity(opacity: 0.4, child: content) : content,
    );
  }
}
