import 'package:flutter/material.dart';

import '../../../core/services/haptics.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import '../pages/assistant/dsh_settings_tabs.dart';

/// The settings tab strip, driven by [DshSettingsTabSpec]s.
///
/// Split out of the page so the spec list is the only thing that decides which
/// tabs exist. The styling is the same soft shell with a filled pill for the
/// selected tab that the old fixed list used, and it scrolls horizontally when the Host
/// reports more tabs than fit.
class DshSettingsTabStrip extends StatelessWidget {
  const DshSettingsTabStrip({
    super.key,
    required this.specs,
    required this.activeId,
    required this.onChanged,
  });

  final List<DshSettingsTabSpec> specs;
  final String activeId;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: context.appColors.surfaceCard,
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.hardEdge,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < specs.length; i++)
              Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : 6),
                child: _DshSettingsTabButton(
                  key:
                      specs[i].key ??
                      ValueKey<String>('dsh-settings-tab-${specs[i].id}'),
                  label: specs[i].label,
                  selected: specs[i].id == activeId,
                  onTap: () {
                    if (specs[i].id == activeId) return;
                    Haptics.light();
                    onChanged(specs[i].id);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DshSettingsTabButton extends StatelessWidget {
  const _DshSettingsTabButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(minWidth: 84, minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? cs.primary.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13.5,
              color: selected
                  ? cs.primary
                  : cs.onSurface.withValues(alpha: 0.82),
              fontWeight: selected
                  ? AppFontWeights.semibold
                  : AppFontWeights.medium,
            ),
          ),
        ),
      ),
    );
  }
}
