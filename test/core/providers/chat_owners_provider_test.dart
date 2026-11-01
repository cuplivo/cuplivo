import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/models/chat_owner.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/chat_owners_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/business_test_harness.dart';

/// One order for assistants and groups, owned by the sidebar and shared with
/// the settings page: dragging in either place moves the same row.
void main() {
  test('a drag in one place is the order everywhere', () async {
    final harness = await createBusinessTestHarness();
    addTearDown(harness.close);

    final assistants = AssistantProvider(preferences: harness.preferences);
    await assistants.loaded;
    final a = await assistants.addAssistant(name: 'A');
    final b = await assistants.addAssistant(name: 'B');
    final c = await assistants.addAssistant(name: 'C');

    final groups = GroupChatProvider(
      store: ExtensionEntityStore(harness.database),
    );
    await groups.loaded;

    final owners = ChatOwnersProvider(
      assistants: assistants,
      groups: groups,
      preferences: harness.preferences,
    );
    await owners.loaded;

    List<String> ids() => [for (final owner in owners.owners) owner.id];

    expect(ids(), [a, b, c]);

    await owners.reorder(2, 0);
    expect(ids(), [c, a, b]);

    // A tag section only ever holds assistants: moving inside it must not
    // reshuffle the rows outside it (here, nothing, but the rule is absolute).
    await owners.reorderWithin(
      keys: {ChatOwner.assistant(a).key, ChatOwner.assistant(b).key},
      oldIndex: 0,
      newIndex: 1,
    );
    expect(ids(), [c, b, a]);

    // The order rides the ordinary preference channel.
    final reopened = ChatOwnersProvider(
      assistants: assistants,
      groups: groups,
      preferences: harness.preferences,
    );
    await reopened.loaded;
    expect([for (final owner in reopened.owners) owner.id], [c, b, a]);
  });

  test('a drag in a mixed section moves only the rows it shows', () async {
    final harness = await createBusinessTestHarness();
    addTearDown(harness.close);

    final assistants = AssistantProvider(preferences: harness.preferences);
    await assistants.loaded;
    final a = await assistants.addAssistant(name: 'A');
    final b = await assistants.addAssistant(name: 'B');
    final c = await assistants.addAssistant(name: 'C');
    final groups = GroupChatProvider(
      store: ExtensionEntityStore(harness.database),
    );
    await groups.loaded;
    final g = await groups.create(name: 'G', memberIds: [a, b]);
    final owners = ChatOwnersProvider(
      assistants: assistants,
      groups: groups,
      preferences: harness.preferences,
    );
    await owners.loaded;
    expect([for (final owner in owners.owners) owner.id], [a, b, c, g.id]);

    // The untagged section shows A, C and the group; B is under a tag header.
    // The sidebar passes section indices here, so dragging A to the end of that
    // section must move exactly those rows and leave B at its absolute position.
    await owners.reorderWithin(
      keys: {
        ChatOwner.assistant(a).key,
        ChatOwner.assistant(c).key,
        ChatOwner.group(g.id).key,
      },
      oldIndex: 0,
      newIndex: 2,
    );
    expect([for (final owner in owners.owners) owner.id], [c, b, g.id, a]);
    expect(
      [
        for (final owner in owners.ungroupedOwners({b})) owner.id,
      ],
      [c, g.id, a],
    );

    // Pickers read the same order, with rows the order has not reconciled yet
    // left at the tail.
    expect(
      owners
          .inOwnerOrder(assistants.assistants, (x) {
            return ChatOwner.assistant(x.id).key;
          })
          .map((x) => x.id),
      [c, b, a],
    );
  });

  test('a new assistant is appended and a deleted one disappears', () async {
    final harness = await createBusinessTestHarness();
    addTearDown(harness.close);

    final assistants = AssistantProvider(preferences: harness.preferences);
    await assistants.loaded;
    final a = await assistants.addAssistant(name: 'A');
    final b = await assistants.addAssistant(name: 'B');
    final groups = GroupChatProvider(
      store: ExtensionEntityStore(harness.database),
    );
    await groups.loaded;
    final owners = ChatOwnersProvider(
      assistants: assistants,
      groups: groups,
      preferences: harness.preferences,
    );
    await owners.loaded;
    await owners.reorder(1, 0);

    final c = await assistants.addAssistant(name: 'C');
    await Future<void>.delayed(Duration.zero);
    expect([for (final owner in owners.owners) owner.id], [b, a, c]);

    await assistants.deleteAssistant(a);
    await Future<void>.delayed(Duration.zero);
    expect([for (final owner in owners.owners) owner.id], [b, c]);
  });
}
