import 'package:flutter/material.dart';

import '../../core/services/haptics.dart';
import '../../icons/lucide_adapter.dart';
import '../../theme/app_font_weights.dart';

/// iOS-style expandable settings group: one card containing a tappable
/// header (leading icon + title + rotating chevron) and an
/// [AnimatedSize]-collapsible body — the "settings group that folds" look
/// shared by workspace tool/dependency sections.
///
/// Controlled: the caller owns the expanded state and drives it through
/// [expanded] + [onToggle].
class IosExpandableSection extends StatefulWidget {
  const IosExpandableSection({
    super.key,
    required this.icon,
    required this.title,
    required this.expanded,
    required this.onToggle,
    this.children = const <Widget>[],
    this.showDivider = false,
    this.enableHaptics = true,
  });

  final IconData icon;
  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final List<Widget> children;

  /// Insert a hairline divider between consecutive [children] when expanded.
  final bool showDivider;

  final bool enableHaptics;

  @override
  State<IosExpandableSection> createState() => _IosExpandableSectionState();
}

class _IosExpandableSectionState extends State<IosExpandableSection> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final titleColor = _pressed
        ? Color.lerp(
            cs.onSurface.withValues(alpha: 0.9),
            isDark ? Colors.white : Colors.black,
            0.55,
          )
        : cs.onSurface.withValues(alpha: 0.9);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.1)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Button semantics + expanded/toggled state, matching the
          // IosIconButton/IosCardPress pattern: the removed page-private
          // _foldHeader used InkWell (button + keyboard focus), so the
          // shared component must not regress assistive tech.
          Semantics(
            button: true,
            expanded: widget.expanded,
            toggled: widget.expanded,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) {
                if (mounted) setState(() => _pressed = true);
              },
              onTapUp: (_) {
                if (mounted) setState(() => _pressed = false);
              },
              onTapCancel: () {
                if (mounted) setState(() => _pressed = false);
              },
              onTap: () {
                if (widget.enableHaptics) Haptics.light();
                widget.onToggle();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 36,
                      child: Icon(widget.icon, size: 20, color: cs.primary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: AppFontWeights.semibold,
                          color: titleColor,
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: widget.expanded ? 0.25 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        Lucide.ChevronRight,
                        size: 18,
                        color: cs.onSurface.withValues(alpha: 0.45),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: widget.expanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < widget.children.length; i++) ...[
                        if (widget.showDivider && i > 0)
                          Divider(
                            height: 1,
                            thickness: 0.6,
                            indent: 12,
                            endIndent: 12,
                            color: cs.outlineVariant.withValues(alpha: 0.18),
                          ),
                        widget.children[i],
                      ],
                    ],
                  )
                : const SizedBox(width: double.infinity, height: 0),
          ),
        ],
      ),
    );
  }
}
