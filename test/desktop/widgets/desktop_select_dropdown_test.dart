import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/desktop/widgets/desktop_select_dropdown.dart';

void main() {
  testWidgets('dropdown options render optional subtitles', (tester) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: DesktopSelectDropdown<String>(
              value: 'a',
              options: const [
                DesktopSelectOption(
                  value: 'a',
                  label: 'Always global',
                  subtitle: 'New memories are shared with every assistant',
                ),
                DesktopSelectOption(
                  value: 'b',
                  label: 'Always this assistant',
                  subtitle: 'New memories stay private to this assistant',
                ),
              ],
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(DesktopSelectDropdown<String>));
    await tester.pumpAndSettle();

    expect(
      find.text('New memories are shared with every assistant'),
      findsOneWidget,
    );
    expect(
      find.text('New memories stay private to this assistant'),
      findsOneWidget,
    );
  });
}
