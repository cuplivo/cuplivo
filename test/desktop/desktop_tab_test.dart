import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/desktop/desktop_tab.dart';
import 'package:Cuplivo/shared/navigation/app_tools.dart';

void main() {
  test('the tab order is what other code indexes into', () {
    // The shell builds its stack from this enum, so `indexOf` *is* a page's
    // position — and `initialTabIndex` is still handed a number from outside
    // the shell (the model sheet passes 3 for Settings). Reordering this list
    // silently sends the stack and that deep link somewhere else, so the order
    // is asserted rather than assumed.
    expect(DesktopTab.values, const [
      DesktopTab.chat,
      DesktopTab.translate,
      DesktopTab.storage,
      DesktopTab.settings,
      DesktopTab.markdownImage,
    ]);
    expect(DesktopTab.values[3], DesktopTab.settings);
  });

  test('every tool has its own tab, and it is a tool tab', () {
    final tabs = AppTool.values.map(desktopTabForTool).toList();
    // Two tools sharing a tab would send both to the same page.
    expect(tabs.toSet().length, AppTool.values.length);
    for (final tool in AppTool.values) {
      expect(desktopTabForTool(tool), isNot(DesktopTab.chat));
      expect(desktopTabForTool(tool), isNot(DesktopTab.settings));
    }
  });

  testWidgets('a page outside the desktop shell is always visible', (
    tester,
  ) async {
    late bool outside;
    late bool inside;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            outside = DesktopTabVisibility.read(context);
            return DesktopTabVisibility(
              visible: false,
              child: Builder(
                builder: (context) {
                  inside = DesktopTabVisibility.read(context);
                  return const SizedBox();
                },
              ),
            );
          },
        ),
      ),
    );

    // True when the scope is absent: a page opened as its own route, and every
    // page on a phone.
    expect(outside, isTrue);
    expect(inside, isFalse);
  });

  testWidgets('reading the flag never makes a page depend on it', (
    tester,
  ) async {
    _Reader.builds = 0;
    var visible = true;
    late StateSetter setVisible;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            setVisible = setState;
            return DesktopTabVisibility(
              visible: visible,
              // Constant, so a rebuild could only come from a dependency.
              child: const _Reader(),
            );
          },
        ),
      ),
    );
    expect(_Reader.seen, isTrue);
    expect(_Reader.builds, 1);

    // Switching tabs must not rebuild the pages being switched between — the
    // flag answers events, it is not a build input. Reading it with
    // `dependOnInheritedWidgetOfExactType` is what made every tab change
    // re-render the export sheet, including the one being hidden.
    setVisible(() => visible = false);
    await tester.pump();
    expect(_Reader.builds, 1);
  });
}

/// Reads the flag without subscribing, and counts the builds that must not
/// happen because of it.
class _Reader extends StatelessWidget {
  const _Reader();

  static int builds = 0;
  static bool seen = false;

  @override
  Widget build(BuildContext context) {
    builds++;
    seen = DesktopTabVisibility.read(context);
    return const SizedBox();
  }
}
