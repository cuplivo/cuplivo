import 'package:flutter/widgets.dart';

/// Marks a tree that is laid out with the export's own rules.
///
/// The preview and the capture both sit under one of these: it turns on the
/// layout a picture will have (expanded code, every table row, no viewport
/// culling) so the two cannot disagree. [renderDiagrams] separates "lay out
/// like the file" from "this tree is about to be rasterised": a capture may not
/// start work, while the preview has to, or it would show source for a picture.
class ExportCaptureScope extends InheritedWidget {
  const ExportCaptureScope({
    super.key,
    required this.enabled,
    this.renderDiagrams = false,
    required super.child,
  });

  final bool enabled;

  /// Whether a diagram block may start its own renderer inside this tree.
  final bool renderDiagrams;

  static bool of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<ExportCaptureScope>();
    return scope?.enabled ?? false;
  }

  /// Whether a diagram may render itself here. Outside a scope — a chat
  /// message — it may; in the capture that is about to be rasterised it may
  /// not, because that work would land in the picture mid-flight.
  static bool diagramsMayRender(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<ExportCaptureScope>();
    return !(scope?.enabled ?? false) || (scope?.renderDiagrams ?? false);
  }

  @override
  bool updateShouldNotify(covariant ExportCaptureScope oldWidget) =>
      oldWidget.enabled != enabled ||
      oldWidget.renderDiagrams != renderDiagrams;
}
