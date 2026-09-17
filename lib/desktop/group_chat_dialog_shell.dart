import 'package:flutter/material.dart';

import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

/// Shared shell for desktop group-chat dialogs (settings, advanced settings,
/// director logs): a compact title row with a close button above a divider,
/// mirroring the desktop assistant settings dialog. The child fills the
/// remaining space (typically an embedded `*Page(embedded: true)` body).
class GroupChatDialogShell extends StatelessWidget {
  const GroupChatDialogShell({
    super.key,
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: AppFontWeights.emphasis,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  icon: const Icon(Lucide.X, size: 18),
                  color: cs.onSurface,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
          ),
        ),
        Divider(
          height: 1,
          thickness: 0.5,
          color: cs.outlineVariant.withValues(alpha: 0.12),
        ),
        Expanded(child: child),
      ],
    );
  }
}
