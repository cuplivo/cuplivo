import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:Cuplivo/theme/app_semantic_colors.dart';

/// The DeepSeek Harness brand mark (the whale glyph).
///
/// The repository already ships the mark for the DeepSeek provider
/// (`assets/icons/deepseek-color.svg`), so the DSH row uses the real brand
/// glyph instead of a generic Lucide icon — the reference's create-menu row and
/// assistant avatar both show it. [color] tints the single-path SVG; leave it
/// null to render the brand colour.
class DshWhaleMark extends StatelessWidget {
  const DshWhaleMark({super.key, this.size = 24, this.color});

  static const String assetPath = 'assets/icons/deepseek-color.svg';

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      assetPath,
      width: size,
      height: size,
      colorFilter: color == null
          ? null
          : ColorFilter.mode(color!, BlendMode.srcIn),
    );
  }
}

/// Round DeepSeek Harness avatar: the whale mark on the same tinted circle the
/// assistant cards use, so a remote owner reads as an owner row at a glance.
class DshWhaleAvatar extends StatelessWidget {
  const DshWhaleAvatar({super.key, this.size = 40, this.background});

  final double size;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg =
        background ??
        Color.alphaBlend(
          cs.primary.withValues(
            alpha: Theme.of(context).brightness == Brightness.dark
                ? 0.24
                : 0.14,
          ),
          context.appColors.surfaceCard,
        );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: DshWhaleMark(
        size: size * 0.56,
        color: cs.onSurface.withValues(alpha: 0.92),
      ),
    );
  }
}
