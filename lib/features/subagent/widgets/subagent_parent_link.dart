import 'dart:async';

import 'package:flutter/material.dart';

import '../../../shared/widgets/ios_tactile.dart';
import '../../../icons/lucide_adapter.dart';

/// `查看主对话 · <parent>` — the first and the last row of a delegated
/// conversation, so the way back is one tap from either end.
///
/// Same geometry as the clear-context divider (28px, hairline on both sides,
/// 12.5px label), because both answer "where am I in this timeline" and the
/// timeline should not have two divider dialects.
class SubagentParentLink extends StatelessWidget {
  const SubagentParentLink({
    super.key,
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = cs.onSurface.withValues(alpha: .55);
    return Semantics(
      button: true,
      label: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: IosCardPress(
          borderRadius: BorderRadius.circular(8),
          baseColor: Colors.transparent,
          onTap: () => unawaited(Future<void>.sync(onTap)),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Divider(
                  height: 1,
                  thickness: 0.5,
                  color: cs.onSurface.withValues(alpha: .08),
                ),
              ),
              const SizedBox(width: 8),
              Icon(Lucide.ChevronLeft, size: 13, color: color),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: color),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Divider(
                  height: 1,
                  thickness: 0.5,
                  color: cs.onSurface.withValues(alpha: .08),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
