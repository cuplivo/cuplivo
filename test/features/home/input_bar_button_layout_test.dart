import 'package:Cuplivo/features/home/utils/input_bar_button_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default order is canonical and complete (16 ids incl. customize)', () {
    expect(defaultInputBarButtonIds, hasLength(16));
    expect(defaultInputBarButtonIds.toSet(), hasLength(16));
    expect(defaultInputBarButtonIds.first, inputBarButtonModel);
    expect(
      defaultInputBarButtonIds[defaultInputBarButtonIds.length - 2],
      inputBarButtonProactiveCare,
    );
    expect(defaultInputBarButtonIds.last, inputBarButtonCustomize);
  });

  test('phone default direct set is exactly the first five', () {
    expect(
      defaultPhoneDirectInputBarButtonIds,
      defaultInputBarButtonIds.take(5).toList(),
    );
  });

  test('saved order wins, unknown ids dropped, missing defaults appended', () {
    final ordered = orderedInputBarButtonIds(
      savedOrder: [
        inputBarButtonCamera,
        'unknown-future-button',
        inputBarButtonModel,
        inputBarButtonCamera, // duplicate
      ],
    );
    expect(ordered.first, inputBarButtonCamera);
    expect(ordered[1], inputBarButtonModel);
    expect(ordered, containsAll(defaultInputBarButtonIds));
    expect(ordered.where((id) => id == inputBarButtonCamera), hasLength(1));
    expect(ordered, hasLength(defaultInputBarButtonIds.length));
  });

  test('empty saved order resolves to canonical order', () {
    final ordered = orderedInputBarButtonIds(savedOrder: const []);
    expect(ordered, defaultInputBarButtonIds);
  });

  group('resolveInputBarButtonLayout', () {
    test('unset phone keeps legacy split (first 5 direct, rest in-more)', () {
      final layout = resolveInputBarButtonLayout(
        savedOrder: const [],
        savedMoreIds: const [],
        tabletLayout: false,
      );
      expect(layout.orderedIds, defaultInputBarButtonIds);
      expect(layout.moreIds, defaultInputBarButtonIds.skip(5).toSet());
      expect(layout.moreIds, contains(inputBarButtonCustomize));
      expect(layout.moreIds, contains(inputBarButtonProactiveCare));
      expect(
        layout.orderedIds.where((id) => !layout.moreIds.contains(id)),
        defaultPhoneDirectInputBarButtonIds,
      );
    });

    test('unset tablet keeps everything direct except the customize entry', () {
      final layout = resolveInputBarButtonLayout(
        savedOrder: const [],
        savedMoreIds: const [],
        tabletLayout: true,
      );
      expect(layout.moreIds, defaultTabletMoreInputBarButtonIds.toSet());
      expect(layout.orderedIds, defaultInputBarButtonIds);
    });

    test('customized layout applies saved more ids on every platform', () {
      final layout = resolveInputBarButtonLayout(
        savedOrder: const [inputBarButtonModel, inputBarButtonCamera],
        savedMoreIds: const [inputBarButtonCamera],
        tabletLayout: true,
      );
      expect(layout.orderedIds.take(2), [
        inputBarButtonModel,
        inputBarButtonCamera,
      ]);
      expect(layout.moreIds, {
        inputBarButtonCamera,
        inputBarButtonProactiveCare,
      });
    });

    test('unknown ids in saved more are dropped', () {
      final layout = resolveInputBarButtonLayout(
        savedOrder: const [inputBarButtonModel],
        savedMoreIds: const ['future-button'],
        tabletLayout: false,
      );
      expect(layout.moreIds, {inputBarButtonProactiveCare});
      expect(layout.orderedIds, defaultInputBarButtonIds);
    });

    test('new action appends into More for an existing saved layout', () {
      final layout = resolveInputBarButtonLayout(
        savedOrder: const [inputBarButtonModel, inputBarButtonCustomize],
        savedMoreIds: const [inputBarButtonCustomize],
        tabletLayout: true,
      );

      expect(layout.moreIds, contains(inputBarButtonProactiveCare));
      expect(layout.orderedIds.first, inputBarButtonModel);
      expect(layout.orderedIds[1], inputBarButtonCustomize);
      expect(layout.orderedIds.last, inputBarButtonProactiveCare);
    });

    test('explicit direct placement of the new action is preserved', () {
      final layout = resolveInputBarButtonLayout(
        savedOrder: const [
          inputBarButtonProactiveCare,
          inputBarButtonModel,
          inputBarButtonCustomize,
        ],
        savedMoreIds: const [inputBarButtonCustomize],
        tabletLayout: false,
      );

      expect(layout.moreIds, isNot(contains(inputBarButtonProactiveCare)));
      expect(layout.orderedIds.first, inputBarButtonProactiveCare);
      expect(layout.orderedIds[2], inputBarButtonCustomize);
    });
  });
}
