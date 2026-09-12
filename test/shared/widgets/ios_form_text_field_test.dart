import 'package:Cuplivo/shared/widgets/ios_form_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget boundedHarness(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320, maxHeight: 360),
          child: child,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('inline mode does not expand under bounded loose height', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      boundedHarness(
        IosFormTextField(
          label: 'Label',
          controller: controller,
          hintText: 'Hint text',
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(IosFormTextField)).height, lessThan(150));
  });

  testWidgets('inline label line height matches the input text', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      boundedHarness(IosFormTextField(label: 'Label', controller: controller)),
    );

    // Regression: the label used its taller natural line box, centering its
    // glyphs ~4px above the input text. Both sides must use the same
    // multiplier (1.15) so their line boxes — and thus baselines — align.
    final label = tester.widget<Text>(find.text('Label'));
    expect(label.style?.height, 1.15);
  });

  testWidgets('column mode single-line does not expand under bounded height', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      boundedHarness(
        IosFormTextField(
          label: 'Label',
          controller: controller,
          hintText: 'Hint text',
          inlineLabel: false,
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(IosFormTextField)).height, lessThan(150));
    expect(tester.getSize(find.byType(TextField)).width, greaterThan(260));
  });

  testWidgets('multi-line mode grows to content, not bounded height', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      boundedHarness(
        IosFormTextField(
          label: 'Label',
          controller: controller,
          maxLines: 3,
          minLines: 3,
          inlineLabel: false,
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(IosFormTextField)).height, lessThan(250));
  });
}
