import 'package:flutter/material.dart';

import '../../../theme/app_font_weights.dart';

/// One full-size status screen inside the DeepSeek Harness surface: the icon,
/// the one sentence describing what is wrong or loading, and the actions that
/// can change it.
///
/// Shared by the embedded WebView (load failures, unsupported platform) and by
/// the tailcat page (tunnel in progress, tunnel failed): those are the same
/// kind of message in the same place, and must not drift into two looks.
class HarnessStatus extends StatelessWidget {
  const HarnessStatus({
    super.key,
    required this.icon,
    required this.title,
    required this.actions,
  });

  final IconData icon;
  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 36, color: colorScheme.onSurfaceVariant),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: AppFontWeights.semibold,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: actions,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
