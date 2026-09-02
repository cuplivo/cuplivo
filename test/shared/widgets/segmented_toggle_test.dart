import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/shared/widgets/segmented_toggle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Finder dotCircles() => find.byWidgetPredicate((widget) {
    return widget is Container &&
        widget.decoration is BoxDecoration &&
        (widget.decoration! as BoxDecoration).shape == BoxShape.circle;
  });

  testWidgets('selected cell shows check and hides its readiness dot', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedToggle(
              options: const ['Local', 'WebDAV', 'S3'],
              value: 1,
              dots: const [Colors.green, Colors.grey, Colors.grey],
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Lucide.Check), findsOneWidget);
    // 3 options - 1 selected = 2 unselected cells keep their dots.
    expect(dotCircles(), findsNWidgets(2));
  });

  testWidgets('no-dots call sites stay unchanged (multi toggle)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedToggleMulti(
              options: const ['Chats', 'Settings', 'Files'],
              isSelected: const [true, false, true],
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Lucide.Check), findsNWidgets(2));
    expect(dotCircles(), findsNothing);
  });
}
