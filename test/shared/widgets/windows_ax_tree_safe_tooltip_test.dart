import 'package:Cuplivo/shared/widgets/windows_ax_tree_safe_tooltip.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Windows tooltips stay in separate semantics containers inside a list item',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ListView(
              children: [
                Row(
                  children: const [
                    WindowsAxTreeSafeTooltip(
                      key: ValueKey('tooltip-a'),
                      message: 'Tooltip A',
                      child: Text('A'),
                    ),
                    WindowsAxTreeSafeTooltip(
                      key: ValueKey('tooltip-b'),
                      message: 'Tooltip B',
                      child: Text('B'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );

        for (final key in const ['tooltip-a', 'tooltip-b']) {
          final containers = tester
              .widgetList<Semantics>(
                find.descendant(
                  of: find.byKey(ValueKey(key)),
                  matching: find.byType(Semantics),
                ),
              )
              .where((widget) => widget.container);
          expect(containers, hasLength(1));
        }

        final traversal = tester.semantics.simulatedAccessibilityTraversal();
        expect(traversal, contains(isSemantics(tooltip: 'Tooltip A')));
        expect(traversal, contains(isSemantics(tooltip: 'Tooltip B')));
      } finally {
        semantics.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('non-Windows tooltip does not add a semantics container', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(
        const MaterialApp(
          home: WindowsAxTreeSafeTooltip(
            key: ValueKey('tooltip'),
            message: 'Tooltip',
            child: Text('child'),
          ),
        ),
      );

      final containers = tester
          .widgetList<Semantics>(
            find.descendant(
              of: find.byKey(const ValueKey('tooltip')),
              matching: find.byType(Semantics),
            ),
          )
          .where((widget) => widget.container);
      expect(containers, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
