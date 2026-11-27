import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The DeepSeek Harness mark, drawn as a tinted glyph so it can stand where a
/// Lucide icon would (create menu, list avatar, drawer row).
///
/// The whale is the product's own mark; the asset keeps only its path and is
/// recolored with [color] to follow the surrounding foreground like every other
/// icon in the app.
class DeepSeekHarnessIcon extends StatelessWidget {
  const DeepSeekHarnessIcon({
    super.key,
    required this.size,
    required this.color,
  });

  static const String asset = 'assets/icons/deepseek-harness.svg';

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      asset,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}
