import 'package:flutter/material.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../shared/widgets/ios_tactile.dart';

/// iOS-style action row: label + optional one-line subtitle, an optional
/// value (and status dot) on the right, optional chevron. Used by both the
/// mobile backup page and the desktop backup pane for the redesigned
/// hierarchy (title + desc, muted values).
class BackupActionRow extends StatelessWidget {
  const BackupActionRow({
    super.key,
    this.icon,
    required this.label,
    this.subtitle,
    this.value,
    this.dotColor,
    this.enabled = true,
    this.onTap,
    this.chevronRotation = 0,
    this.labelMaxLines = 1,
    this.subtitleMaxLines = 1,
  });

  final IconData? icon;
  final String label;
  final String? subtitle;
  final String? value;
  final Color? dotColor;
  final bool enabled;
  final VoidCallback? onTap;

  /// Rotates the trailing chevron (e.g. pi/2 for an expanding row).
  final double chevronRotation;

  /// Label overflow cap. The migration chooser passes 2 so long localized
  /// labels wrap instead of truncating.
  final int labelMaxLines;
  final int subtitleMaxLines;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dim = enabled ? 1.0 : 0.38;
    final titleColor = cs.onSurface.withValues(alpha: 0.88 * dim);
    final subColor = cs.onSurface.withValues(alpha: 0.48 * dim);
    final valueColor = cs.onSurface.withValues(alpha: 0.55 * dim);
    final interactive = enabled && onTap != null;

    return IosCardPress(
      onTap: interactive ? onTap : null,
      baseColor: Colors.transparent,
      pressedBlendStrength: 0.06,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: [
            if (icon != null) ...[
              Container(
                width: 36,
                alignment: Alignment.centerLeft,
                child: Icon(
                  icon,
                  size: 20,
                  color: cs.onSurface.withValues(alpha: 0.42 * dim),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              // 内层 spaceBetween：label（Flexible 先缩）与尾部簇（自然宽）
              // 之间的全部 slack 落进一个间隙，尾部簇永远 flush right。
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          maxLines: labelMaxLines,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 15, color: titleColor),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            maxLines: subtitleMaxLines,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12.5, color: subColor),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // value：自然宽度（有界短串），遇窄时由 label 先行
                      // 省略；dot/chevron 跟随其后贴齐行右侧。
                      if (value != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 10),
                          child: Text(
                            value!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: valueColor),
                          ),
                        ),
                      if (dotColor != null && value != null) ...[
                        const SizedBox(width: 6),
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: dotColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                      if (interactive) ...[
                        const SizedBox(width: 4),
                        AnimatedRotation(
                          turns: chevronRotation / (2 * 3.141592653589793),
                          duration: const Duration(milliseconds: 160),
                          curve: Curves.easeOutCubic,
                          child: Icon(
                            Lucide.ChevronRight,
                            size: 16,
                            color: cs.onSurface.withValues(alpha: 0.32 * dim),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
