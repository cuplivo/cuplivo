import 'package:flutter/material.dart';

import 'package:Cuplivo/theme/app_semantic_colors.dart';

import '../state/dsh_gateway.dart';

/// A small coloured dot that reports one remote's live link.
///
/// Used by the owner rows (drawer and the assistant settings list) so a dead
/// link is visible before it is opened, matching the app's existing status-dot
/// language. The dot is decorative; callers that need the failure text render
/// it through [dshLinkStatusLabel].
class DshLinkStatusDot extends StatelessWidget {
  const DshLinkStatusDot({
    super.key,
    required this.status,
    this.size = 8,
    this.semanticLabel,
  });

  final DshLinkStatus status;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final color = switch (status.state) {
      DshLinkState.ready => colors.success,
      DshLinkState.connecting => colors.warning,
      DshLinkState.failed => cs.error,
      DshLinkState.idle => cs.onSurface.withValues(alpha: 0.28),
    };
    final dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    final label = semanticLabel;
    if (label == null) return ExcludeSemantics(child: dot);
    return Semantics(label: label, child: dot);
  }
}
