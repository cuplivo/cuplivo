import 'package:flutter/material.dart';

import '../../../core/models/assistant.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../theme/app_font_weights.dart';
import '../../home/widgets/assistant_avatar.dart';

/// The group's identity in the composer: every member's face collapsed into one
/// target.
///
/// One tap opens the member list — not a per-avatar action and not a model
/// picker. A group has no single model, so the slot a 1:1 chat spends on "which
/// model am I talking to" is spent here on "who is in this room".
class GroupMemberCluster extends StatelessWidget {
  const GroupMemberCluster({
    super.key,
    required this.members,
    this.onTap,
    this.size = avatarSize,
  });

  static const double avatarSize = 22;
  static const double _step = 6;

  /// The width [members] needs. The composer reserves it so a two-member group
  /// and a five-member group do not shift the text row.
  static double extentFor(int memberCount) {
    final layers = _layersFor(memberCount);
    return avatarSize + (layers - 1) * _step;
  }

  static int _layersFor(int memberCount) {
    if (memberCount <= 0) return 1; // the invite circle alone
    final avatars = memberCount > 4 ? 3 : memberCount;
    final overflow = memberCount > 4 ? 1 : 0;
    return avatars + overflow + 1;
  }

  final List<Assistant> members;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final avatars = members.length > 4 ? members.take(3) : members;
    final overflow = members.length > 4 ? members.length - 3 : 0;

    final layers = <Widget>[];
    var index = 0;
    double leftFor(int i) => i * _step;

    for (final member in avatars) {
      layers.add(
        Positioned(
          left: leftFor(index++),
          top: 0,
          child: _Ring(
            color: isDark ? cs.surface : cs.surfaceContainerHighest,
            child: AssistantAvatar(assistant: member, size: size),
          ),
        ),
      );
    }
    if (overflow > 0) {
      layers.add(
        Positioned(
          left: leftFor(index++),
          top: 0,
          child: _Ring(
            color: isDark ? cs.surface : cs.surfaceContainerHighest,
            child: Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Text(
                '+$overflow',
                style: TextStyle(
                  fontSize: 9,
                  height: 1,
                  fontWeight: AppFontWeights.semibold,
                  color: cs.onSurface.withValues(alpha: 0.72),
                ),
              ),
            ),
          ),
        ),
      );
    }
    layers.add(
      Positioned(
        left: leftFor(index),
        top: 0,
        child: _Ring(
          color: isDark ? cs.surface : cs.surfaceContainerHighest,
          child: Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Lucide.Plus,
              size: 12,
              color: cs.primary.withValues(alpha: 0.9),
            ),
          ),
        ),
      ),
    );

    return Semantics(
      button: onTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: extentFor(members.length),
          height: size + 2,
          child: Stack(clipBehavior: Clip.none, children: layers),
        ),
      ),
    );
  }
}

/// A ring in the composer's surface colour, so overlapping faces stay legible
/// as separate people rather than merging into one blob.
class _Ring extends StatelessWidget {
  const _Ring({required this.child, required this.color});

  final Widget child;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      padding: const EdgeInsets.all(1),
      child: child,
    );
  }
}
