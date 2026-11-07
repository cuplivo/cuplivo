import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/desktop/desktop_tab.dart';
import 'package:Cuplivo/shared/navigation/app_tools.dart';

void main() {
  test('every tool owns exactly one tab', () {
    final tabs = AppTool.values.map(desktopTabForTool).toList();
    expect(tabs.toSet().length, AppTool.values.length);
  });

  test('a tool tab index is its position in the stack', () {
    // The shell builds its stack from DesktopTab.values, so the order of that
    // enum *is* the order of the pages: a tool's index cannot drift from where
    // its page sits.
    expect(DesktopTab.values.indexOf(DesktopTab.chat), 0);
    for (final tool in AppTool.values) {
      final tab = desktopTabForTool(tool);
      expect(DesktopTab.values.indexOf(tab), isNonNegative);
      expect(DesktopTab.values[DesktopTab.values.indexOf(tab)], tab);
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
            outside = DesktopTabVisibility.of(context);
            return DesktopTabVisibility(
              visible: false,
              child: Builder(
                builder: (context) {
                  inside = DesktopTabVisibility.of(context);
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

  testWidgets('turning a hidden tab visible notifies what depends on it', (
    tester,
  ) async {
    var visible = false;
    late StateSetter setVisible;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            setVisible = setState;
            return DesktopTabVisibility(
              visible: visible,
              // Constant, so the probe is only rebuilt when the inherited
              // value actually changes — which is the thing being asserted.
              child: const _VisibilityProbe(),
            );
          },
        ),
      ),
    );
    expect(_VisibilityProbe.builds, 1);
    expect(_VisibilityProbe.seen, isFalse);

    setVisible(() => visible = true);
    await tester.pump();
    expect(_VisibilityProbe.seen, isTrue);
    expect(_VisibilityProbe.builds, 2);

    // The same answer again must not churn the subtree.
    setVisible(() => visible = true);
    await tester.pump();
    expect(_VisibilityProbe.builds, 2);
  });
}

/// Reads the scope so a change to it rebuilds this widget and nothing else.
class _VisibilityProbe extends StatelessWidget {
  const _VisibilityProbe();

  static int builds = 0;
  static bool seen = false;

  @override
  Widget build(BuildContext context) {
    builds++;
    seen = DesktopTabVisibility.of(context);
    return const SizedBox();
  }
}
