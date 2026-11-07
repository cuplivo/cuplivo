import 'package:flutter/material.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';

/// One secondary action of the tool: bring text in from a file or a clipboard.
class MarkdownExportActionChip extends StatelessWidget {
  const MarkdownExportActionChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final cs = Theme.of(context).colorScheme;
    return IosCardPress(
      borderRadius: BorderRadius.circular(12),
      baseColor: colors.surfaceCard,
      border: Border.all(color: colors.hairline, width: 0.6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: cs.onSurface.withValues(alpha: .72)),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: AppFontWeights.semibold,
              color: cs.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// The one primary action: turn what is on screen into a picture.
class MarkdownExportButton extends StatelessWidget {
  const MarkdownExportButton({
    super.key,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final String label;

  /// `null` while there is nothing to export.
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = onTap != null && !busy;
    final foreground = enabled
        ? cs.onPrimary
        : cs.onSurface.withValues(alpha: .45);
    return IosCardPress(
      borderRadius: BorderRadius.circular(12),
      baseColor: enabled ? cs.primary : cs.onSurface.withValues(alpha: .07),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(foreground),
              ),
            )
          else
            Icon(Lucide.ImageDown, size: 16, color: foreground),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: AppFontWeights.semibold,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}
