import 'package:Cuplivo/features/assistant/utils/assistant_edit_tab_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('roleplay tab sits between memory and local tools on Android order', () {
    final order = defaultAssistantEditTabIdsWithRoleplay;
    expect(order, contains(assistantEditTabRoleplay));
    expect(
      order.indexOf(assistantEditTabMemory) + 1,
      order.indexOf(assistantEditTabRoleplay),
    );
    expect(
      order.indexOf(assistantEditTabRoleplay) + 1,
      order.indexOf(assistantEditTabLocalTools),
    );
    // The base order is untouched for non-Android platforms.
    expect(
      defaultAssistantEditTabIds,
      isNot(contains(assistantEditTabRoleplay)),
    );
  });

  test(
    'saved custom orders absorb the roleplay tab at the default position',
    () {
      // A user with a customized order (no roleplay entry) keeps their order;
      // the new tab is appended where the default says it belongs.
      final ordered = orderAssistantEditTabIds(
        savedOrder: [
          assistantEditTabBasic,
          assistantEditTabRegex,
          assistantEditTabPrompts,
        ],
        defaultOrder: defaultAssistantEditTabIdsWithRoleplay,
      );
      expect(ordered, contains(assistantEditTabRoleplay));
      expect(ordered.first, assistantEditTabBasic);
      expect(ordered[1], assistantEditTabRegex);
      // Missing tabs fill in default order after the saved ones.
      expect(ordered[3], assistantEditTabMemory);
      expect(ordered[4], assistantEditTabRoleplay);
      expect(ordered[5], assistantEditTabLocalTools);
    },
  );

  test('hidden tabs are filtered but never leave an empty bar', () {
    final visible = visibleAssistantEditTabIds(
      savedOrder: const [],
      hiddenIds: {assistantEditTabRoleplay},
      defaultOrder: defaultAssistantEditTabIdsWithRoleplay,
    );
    expect(visible, isNot(contains(assistantEditTabRoleplay)));
    expect(visible.first, assistantEditTabBasic);
  });
}
