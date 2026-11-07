import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../theme/app_font_weights.dart';

/// Accepts files dropped anywhere on [child], with the drop look the chat page
/// already uses: the surface dims and one bordered card says what will happen.
class MarkdownExportDropTarget extends StatefulWidget {
  const MarkdownExportDropTarget({
    super.key,
    required this.child,
    required this.onPaths,
  });

  final Widget child;

  /// Paths of the dropped files, in the order the platform reported them.
  final ValueChanged<List<String>> onPaths;

  @override
  State<MarkdownExportDropTarget> createState() =>
      _MarkdownExportDropTargetState();
}

class _MarkdownExportDropTargetState extends State<MarkdownExportDropTarget> {
  bool _hovering = false;

  void _setHovering(bool value) {
    if (_hovering == value) return;
    setState(() => _hovering = value);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) => _setHovering(true),
      onDragExited: (_) => _setHovering(false),
      onDragDone: (details) {
        _setHovering(false);
        widget.onPaths([for (final file in details.files) file.path]);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_hovering)
            IgnorePointer(
              child: ColoredBox(
                color: cs.scrim.withValues(alpha: 0.12),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: cs.surface.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: cs.primary.withValues(alpha: 0.4),
                        width: 2,
                      ),
                    ),
                    child: Text(
                      AppLocalizations.of(context)!.markdownExportDropHint,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: AppFontWeights.semibold,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
