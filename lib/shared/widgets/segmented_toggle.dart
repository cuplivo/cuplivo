import 'package:flutter/material.dart';

import '../../icons/lucide_adapter.dart';
import '../../theme/app_font_weights.dart';
import '../../theme/app_semantic_colors.dart';

/// iOS-style single-select segmented control (the "模型类型" look):
/// one `surfaceFill` base with an outline, selected option tinted with
/// `primary` (14% light / 20% dark) + a check icon.
class SegmentedToggle extends StatelessWidget {
  const SegmentedToggle({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.itemsPerRow = 0,
    this.dots,
  });

  final List<String> options;
  final int value; // index
  final ValueChanged<int> onChanged;

  /// > 1 chops the options into rows of that many (e.g. 3 → 2×3 grid).
  final int itemsPerRow;

  /// Trailing status-dot color per option (index-aligned); null entry = no
  /// dot. Used by the backup hero destination picker (green = configured,
  /// grey = unconfigured) without affecting other call sites. A dot only
  /// renders on UNselected cells — the selected cell shows the check icon
  /// instead (check and dot are mutually exclusive).
  final List<Color?>? dots;

  @override
  Widget build(BuildContext context) {
    assert(dots == null || dots!.length == options.length);
    return _SegmentedBase(
      options: options,
      itemsPerRow: itemsPerRow,
      isSelected: [for (var i = 0; i < options.length; i++) i == value],
      onChanged: onChanged,
      multi: false,
      dots: dots,
    );
  }
}

/// iOS-style multi-select segment (the model "能力" look): same base,
/// several options selectable; the all-selected state overlays the tint
/// across the whole base instead of per-cell.
class SegmentedToggleMulti extends StatelessWidget {
  const SegmentedToggleMulti({
    super.key,
    required this.options,
    required this.isSelected,
    required this.onChanged,
    this.allowEmpty = false,
    this.itemsPerRow = 0,
  });

  final List<String> options;
  final List<bool> isSelected;
  final ValueChanged<int> onChanged;
  final bool allowEmpty;

  /// > 1 chops the options into rows of that many (e.g. 3 → 2×3 grid).
  final int itemsPerRow;

  @override
  Widget build(BuildContext context) {
    return _SegmentedBase(
      options: options,
      itemsPerRow: itemsPerRow,
      isSelected: isSelected,
      onChanged: onChanged,
      multi: true,
      allowEmpty: allowEmpty,
    );
  }
}

class _SegmentedBase extends StatelessWidget {
  const _SegmentedBase({
    required this.options,
    required this.itemsPerRow,
    required this.isSelected,
    required this.onChanged,
    required this.multi,
    this.allowEmpty = false,
    this.dots,
  });

  final List<String> options;
  final int itemsPerRow;
  final List<bool> isSelected;
  final ValueChanged<int> onChanged;
  final bool multi;
  final bool allowEmpty;
  final List<Color?>? dots;

  @override
  Widget build(BuildContext context) {
    assert(options.length == isSelected.length);
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bool allSelected =
        isSelected.isNotEmpty && isSelected.every((e) => e);
    final int selectedCount = isSelected.where((e) => e).length;
    final base = context.appColors.surfaceFill;
    final sel = isDark
        ? cs.primary.withValues(alpha: 0.20)
        : cs.primary.withValues(alpha: 0.14);
    final r = BorderRadius.circular(12);
    final perRow = itemsPerRow <= 0 ? options.length : itemsPerRow;
    final grid = perRow < options.length;

    BorderRadius cellRadius(int index, int count) {
      if (!multi) return r;
      if (grid) return r;
      if (selectedCount == 1 && isSelected[index]) return r;
      if (index == 0) {
        return const BorderRadius.only(
          topLeft: Radius.circular(12),
          bottomLeft: Radius.circular(12),
        );
      }
      if (index == count - 1) {
        return const BorderRadius.only(
          topRight: Radius.circular(12),
          bottomRight: Radius.circular(12),
        );
      }
      return BorderRadius.zero;
    }

    final rows = <Widget>[];
    for (var start = 0; start < options.length; start += perRow) {
      final end = (start + perRow).clamp(0, options.length);
      rows.add(
        Row(
          children: [
            for (var j = start; j < end; j++)
              Expanded(
                child: InkWell(
                  splashColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                  onTap: () => onChanged(j),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      // 全选时子项透明，让上面的整条遮罩生效；
                      // 非全选时按原逻辑逐项着色
                      color: multi && allSelected
                          ? Colors.transparent
                          : (isSelected[j] ? sel : Colors.transparent),
                      borderRadius: cellRadius(j, end - start),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (isSelected[j])
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Icon(
                              Lucide.Check,
                              size: 16,
                              color: cs.primary,
                            ),
                          ),
                        Flexible(
                          child: Text(
                            options[j],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurface,
                              fontWeight: AppFontWeights.semibold,
                            ),
                          ),
                        ),
                        // 就绪点：仅未选中 cell 渲染（选中时由 √ 替代，
                        // 二者互斥，避免叠加挤压 label 宽度）。
                        if (!isSelected[j] &&
                            dots != null &&
                            dots![j] != null) ...[
                          const SizedBox(width: 5),
                          Container(
                            width: 7,
                            height: 7,
                            margin: const EdgeInsets.only(top: 1),
                            decoration: BoxDecoration(
                              color: dots![j],
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        color: base, // 外层始终用同一个"底色"
        border: Border.all(
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: ClipRRect(
        borderRadius: r,
        child: Stack(
          children: [
            // 全选时：在"同一个底色"上叠加一层 sel（与单选的叠加路径一致）
            if (multi && allSelected)
              Positioned.fill(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  decoration: BoxDecoration(color: sel, borderRadius: r),
                ),
              ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) const SizedBox(height: 4),
                  rows[i],
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
