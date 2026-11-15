import 'package:flutter/material.dart';

import '../../../core/models/assistant.dart';
import '../../../core/services/haptics.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../../home/widgets/assistant_avatar.dart';

/// The roster as a row of chips at the top of a group panel: one chip per
/// member, carrying that member's current value for the capability the panel
/// edits. Tapping a chip makes it the member the panel writes to.
///
/// Display is per roster while the write follows the selected chip, which is
/// why this strip lives inside the panel and never on the composer.
class GroupMemberStrip extends StatelessWidget {
  const GroupMemberStrip({
    super.key,
    required this.members,
    required this.selectedId,
    required this.onSelect,
    this.valueBuilder,
  });

  static Key chipKey(String assistantId) =>
      ValueKey<String>('group-member-strip-$assistantId');

  final List<Assistant> members;
  final String selectedId;
  final ValueChanged<Assistant> onSelect;

  /// The member's value for this panel, or null to show the name alone (an
  /// off or unsupported value is better shown as nothing than as a word).
  final Widget? Function(Assistant member)? valueBuilder;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: 28,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: members.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final member = members[index];
          final selected = member.id == selectedId;
          final name = member.name.trim().isEmpty ? member.id : member.name;
          final value = valueBuilder?.call(member);
          return IosCardPress(
            key: GroupMemberStrip.chipKey(member.id),
            haptics: false,
            borderRadius: BorderRadius.circular(999),
            baseColor: selected
                ? cs.primary.withValues(alpha: isDark ? 0.18 : 0.10)
                : cs.onSurface.withValues(alpha: isDark ? 0.08 : 0.05),
            pressedScale: 0.97,
            onTap: () {
              Haptics.light();
              onSelect(member);
            },
            padding: const EdgeInsetsDirectional.fromSTEB(4, 0, 10, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AssistantAvatar(assistant: member, size: 20),
                const SizedBox(width: 6),
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected
                        ? AppFontWeights.semibold
                        : AppFontWeights.regular,
                    color: selected
                        ? cs.primary
                        : cs.onSurface.withValues(alpha: 0.62),
                  ),
                ),
                if (value != null) ...[
                  const SizedBox(width: 6),
                  DefaultTextStyle.merge(
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: AppFontWeights.regular,
                      color: selected
                          ? cs.primary.withValues(alpha: 0.8)
                          : cs.onSurface.withValues(alpha: 0.45),
                    ),
                    child: value,
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
