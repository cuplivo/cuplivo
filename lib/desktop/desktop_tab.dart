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
/// asking whether it is visible — ask this before acting.
class DesktopTabVisibility extends InheritedWidget {
  const DesktopTabVisibility({
    super.key,
    required this.visible,
    required super.child,
  });

  final bool visible;

  /// The answer right now, deliberately **without** registering a dependency.
  ///
  /// It is asked from event handlers, not from `build`: a page that depended on
  /// this flag would be rebuilt on every tab switch — including when it is the
  /// page being hidden — and so would the sub-tree inside it. The flag decides
  /// whether an event is acted on, and nothing about how the page looks.
  static bool read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DesktopTabVisibility>()?.visible ??
      // Outside the desktop shell: a page opened as its own route is the only
      // thing on screen, and the phone shell hides its tabs instead of stacking
      // them.
      true;

  @override
  bool updateShouldNotify(DesktopTabVisibility oldWidget) =>
      visible != oldWidget.visible;
}
