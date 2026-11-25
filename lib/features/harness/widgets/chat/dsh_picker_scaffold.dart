import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_tactile.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

/// Adaptive container shared by the DSH pickers.
///
/// Mobile is a draggable bottom sheet (AGENTS.md allows bottom sheets there),
/// desktop is a centred dialog — never a bottom sheet on desktop. Both carry
/// the same header and hand a [ScrollController] to [bodyBuilder] so the body
/// can be a lazy list.
///
/// [bodyBuilder] is called again on every rebuild; it must not hold state.
Future<T?> showDshPicker<T>({
  required BuildContext context,
  required String title,
  required Widget Function(
    BuildContext context,
    ScrollController scrollController,
  )
  bodyBuilder,
  Key? panelKey,
}) {
  final isDesktop =
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
  if (isDesktop) {
    return _showDshPickerDialog<T>(
      context: context,
      title: title,
      bodyBuilder: bodyBuilder,
      panelKey: panelKey,
    );
  }
  return _showDshPickerSheet<T>(
    context: context,
    title: title,
    bodyBuilder: bodyBuilder,
    panelKey: panelKey,
  );
}

Future<T?> _showDshPickerSheet<T>({
  required BuildContext context,
  required String title,
  required Widget Function(BuildContext, ScrollController) bodyBuilder,
  Key? panelKey,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      return SafeArea(
        top: false,
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.78,
            minChildSize: 0.35,
            maxChildSize: 0.92,
            builder: (context, scrollController) {
              return Container(
                key: panelKey,
                decoration: BoxDecoration(
                  color: context.overlaySurface,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                ),
                child: Column(
                  children: [
                    _DshPickerHeader(title: title, showHandle: true),
                    Expanded(child: bodyBuilder(context, scrollController)),
                  ],
                ),
              );
            },
          ),
        ),
      );
    },
  );
}

Future<T?> _showDshPickerDialog<T>({
  required BuildContext context,
  required String title,
  required Widget Function(BuildContext, ScrollController) bodyBuilder,
  Key? panelKey,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.25),
    pageBuilder: (dialogContext, _, _) => _DshPickerDialog<T>(
      title: title,
      bodyBuilder: bodyBuilder,
      panelKey: panelKey,
    ),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.98, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _DshPickerDialog<T> extends StatefulWidget {
  const _DshPickerDialog({
    required this.title,
    required this.bodyBuilder,
    this.panelKey,
  });

  final String title;
  final Widget Function(BuildContext, ScrollController) bodyBuilder;
  final Key? panelKey;

  @override
  State<_DshPickerDialog<T>> createState() => _DshPickerDialogState<T>();
}

class _DshPickerDialogState<T> extends State<_DshPickerDialog<T>> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 460,
          maxWidth: 620,
          maxHeight: 560,
        ),
        child: Material(
          color: context.overlaySurface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: isDark
                  ? cs.onSurface.withValues(alpha: 0.08)
                  : cs.outlineVariant.withValues(alpha: 0.25),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _DshPickerHeader(title: widget.title, key: widget.panelKey),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: cs.outlineVariant.withValues(alpha: 0.18),
                ),
                Expanded(child: widget.bodyBuilder(context, _scrollController)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DshPickerHeader extends StatelessWidget {
  const _DshPickerHeader({
    super.key,
    required this.title,
    this.showHandle = false,
  });

  final String title;
  final bool showHandle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showHandle) ...[
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: cs.onSurface.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: AppFontWeights.semibold,
                    color: cs.onSurface,
                  ),
                ),
              ),
              IosIconButton(
                icon: Lucide.X,
                size: 18,
                minSize: 36,
                tooltip: l10n.commonClose,
                semanticLabel: l10n.commonClose,
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A section header inside a DSH picker: small caps-ish label plus optional
/// trailing note.
class DshPickerSectionHeader extends StatelessWidget {
  const DshPickerSectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: AppFontWeights.semibold,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// An honest "nothing to choose" state for a picker body.
class DshPickerEmptyState extends StatelessWidget {
  const DshPickerEmptyState({super.key, required this.message, this.icon});

  final String message;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 32, color: cs.onSurface.withValues(alpha: 0.35)),
              const SizedBox(height: 12),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.4,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
