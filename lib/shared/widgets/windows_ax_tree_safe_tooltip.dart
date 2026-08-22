import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A Material tooltip isolated from sibling tooltip traversal anchors on
/// Windows.
///
/// Flutter 3.44 can merge multiple [Tooltip] traversal-parent semantics into
/// one `IndexedSemantics` node (for example, inside a chat [ListView]). Only
/// one traversal identifier survives that merge, so Windows receives an
/// orphan accessibility node and rejects the entire AXTree update. Giving
/// every tooltip its own semantics container prevents that merge while
/// preserving the native tooltip UI and accessibility description.
///
/// Remove the Windows-specific container once the framework fix for
/// https://github.com/flutter/flutter/issues/182444 reaches the minimum
/// supported Flutter stable version.
class WindowsAxTreeSafeTooltip extends StatelessWidget {
  const WindowsAxTreeSafeTooltip({
    super.key,
    required this.message,
    required this.child,
  });

  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tooltip = Tooltip(message: message, child: child);
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return tooltip;
    }
    return Semantics(container: true, child: tooltip);
  }
}
