import 'package:flutter/material.dart';

import 'package:Cuplivo/theme/app_font_weights.dart';

/// The Cuplivo-style centred state used by the DSH 模型 surfaces.
///
/// One widget for loading, empty, not-connected and capability states so they
/// never drift into three different layouts; the icon is the only visual
/// difference and optional [action] is a text button under the body.
class DshModelsStatePanel extends StatelessWidget {
  const DshModelsStatePanel({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String? body;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bodyText = body?.trim() ?? '';
    final action = actionLabel?.trim() ?? '';
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 32,
          vertical: compact ? 18 : 40,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: compact ? 26 : 34,
              color: cs.onSurface.withValues(alpha: 0.35),
            ),
            SizedBox(height: compact ? 10 : 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: compact ? 14 : 16,
                fontWeight: AppFontWeights.semibold,
                color: cs.onSurface.withValues(alpha: 0.85),
              ),
            ),
            if (bodyText.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                bodyText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
            if (action.isNotEmpty && onAction != null) ...[
              const SizedBox(height: 12),
              TextButton(onPressed: onAction, child: Text(action)),
            ],
          ],
        ),
      ),
    );
  }
}
