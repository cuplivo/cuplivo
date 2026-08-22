import 'package:Cuplivo/shared/widgets/sf_slider_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_sliders/sliders.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: 300, child: child)),
      ),
    );
  }

  testWidgets('renders SfSlider with min/max/value and stepped size', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SfSliderTile(
          value: 1536,
          min: 768,
          max: 4096,
          divisions: 13,
          label: '1536px',
          onChanged: (_) {},
        ),
      ),
    );

    final slider = tester.widget<SfSlider>(find.byType(SfSlider));
    expect(slider.min, 768);
    expect(slider.max, 4096);
    expect(slider.value, 1536);
    // step = (4096 - 768) / 13 = 256
    expect(slider.stepSize, 256);
    expect(slider.enableTooltip, isTrue);
    expect(slider.shouldAlwaysShowTooltip, isFalse);
  });

  testWidgets('continuous slider has no step size', (tester) async {
    await tester.pumpWidget(
      wrap(
        SfSliderTile(
          value: 0.5,
          min: 0.1,
          max: 1.0,
          label: '0.50',
          onChanged: (_) {},
        ),
      ),
    );

    final slider = tester.widget<SfSlider>(find.byType(SfSlider));
    expect(slider.stepSize, isNull);
  });

  testWidgets('null onChanged disables the slider', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SfSliderTile(
          value: 75,
          min: 30,
          max: 100,
          divisions: 70,
          label: '—',
          onChanged: null,
        ),
      ),
    );

    final slider = tester.widget<SfSlider>(find.byType(SfSlider));
    expect(slider.onChanged, isNull);
  });

  testWidgets('clamps out-of-range value before rendering', (tester) async {
    await tester.pumpWidget(
      wrap(
        SfSliderTile(
          value: 9999,
          min: 50,
          max: 95,
          divisions: 9,
          label: '9999%',
          onChanged: (_) {},
        ),
      ),
    );

    final slider = tester.widget<SfSlider>(find.byType(SfSlider));
    expect(slider.value, 95);
  });

  testWidgets('dragging fires onChanged with a step-aligned value', (
    tester,
  ) async {
    final values = <double>[];
    await tester.pumpWidget(
      wrap(
        SfSliderTile(
          value: 50,
          min: 0,
          max: 100,
          divisions: 4,
          label: '50',
          onChanged: values.add,
        ),
      ),
    );

    await tester.drag(find.byType(SfSlider), const Offset(100, 0));
    await tester.pumpAndSettle();
    // Drain the slider's tooltip show/hide timers before the test ends.
    await tester.pump(const Duration(seconds: 1));

    expect(values, isNotEmpty);
    final allowed = <double>{0, 25, 50, 75, 100};
    for (final v in values) {
      expect(allowed.contains(v), isTrue, reason: 'off-step value $v');
    }
  });

  testWidgets('dragging a continuous slider fires onChanged and onChangeEnd', (
    tester,
  ) async {
    final changed = <double>[];
    final ended = <double>[];
    await tester.pumpWidget(
      wrap(
        SfSliderTile(
          value: 0.1,
          min: 0.1,
          max: 1.0,
          label: '0.10',
          onChanged: changed.add,
          onChangeEnd: ended.add,
        ),
      ),
    );

    await tester.drag(find.byType(SfSlider), const Offset(100, 0));
    await tester.pumpAndSettle();
    // Drain the slider's tooltip show/hide timers before the test ends.
    await tester.pump(const Duration(seconds: 1));

    expect(changed, isNotEmpty);
    expect(ended, isNotEmpty);
    expect(changed.last, inInclusiveRange(0.1, 1.0));
    expect(ended.last, changed.last);
  });

  testWidgets(
    'exposes a labeled semantics node with value and adjust actions',
    (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        wrap(
          SfSliderTile(
            value: 80,
            min: 50,
            max: 95,
            divisions: 9,
            label: '80%',
            semanticLabel: 'quality',
            semanticFormatterCallback: (value) => '${value.round()}%',
            onChanged: (_) {},
          ),
        ),
      );

      // The label lives on the wrapping node, the value and adjust actions on
      // SfSlider's own semantics node; both are visible to assistive
      // technologies.
      final nodes = tester.semantics.simulatedAccessibilityTraversal();
      expect(nodes, contains(isSemantics(label: 'quality')));
      expect(
        nodes,
        contains(
          isSemantics(
            value: '80%',
            increasedValue: '85%',
            decreasedValue: '75%',
            hasIncreaseAction: true,
            hasDecreaseAction: true,
          ),
        ),
      );

      handle.dispose();
    },
  );
}
