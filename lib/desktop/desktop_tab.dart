import 'package:flutter/widgets.dart';

import '../shared/navigation/app_tools.dart';

/// The desktop shell's tabs, in the order its stack lays them out.
///
/// A tab's index is the index of its value here, and the stack is built from
/// [values], so the rail and the stack cannot disagree about which page a
/// button opens. Adding a tab is one value here plus one arm in the shell's
/// page builder; a tool that forgets to pick a tab fails to compile.
enum DesktopTab { chat, translate, storage, settings, markdownImage }

/// The tab that shows [tool].
DesktopTab desktopTabForTool(AppTool tool) => switch (tool) {
  AppTool.translate => DesktopTab.translate,
  AppTool.storage => DesktopTab.storage,
  AppTool.markdownImage => DesktopTab.markdownImage,
};

/// Whether the desktop tab around [context] is the one on screen.
///
/// `IndexedStack` builds every tab, and a hidden tab is laid out at the visible
/// tab's rect. Widgets that answer a process-wide event rather than a pointer —
/// `desktop_drop` broadcasts every drop to every registered target without
/// asking whether it is visible — read this instead of assuming they are shown.
class DesktopTabVisibility extends InheritedWidget {
  const DesktopTabVisibility({
    super.key,
    required this.visible,
    required super.child,
  });

  final bool visible;

  /// True outside the desktop shell: a page opened as its own route is the only
  /// thing on screen, and the phone shell hides its tabs instead of stacking
  /// them.
  static bool of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<DesktopTabVisibility>();
    return scope?.visible ?? true;
  }

  @override
  bool updateShouldNotify(DesktopTabVisibility oldWidget) =>
      visible != oldWidget.visible;
}
