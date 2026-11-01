// A group is edited field by field, and several of those edits finish after an
// await: the 400 ms rename debounce, the avatar menu, the member picker, the
// removal confirmation. Each write therefore has to read-modify-write the row
// that is there now — writing back the snapshot a widget captured is how one
// edit silently undoes another.

import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/business_test_harness.dart';

void main() {
  late ExtensionEntityStore store;

  GroupChatProvider providerFor(ExtensionEntityStore store) =>
      GroupChatProvider(store: store);

  setUp(() {
    store = ExtensionEntityStore(
      createBusinessTestPreferencesWithDatabase().database,
    );
  });

  test('two edits started from the same snapshot both land', () async {
    final groups = providerFor(store);
    await groups.loaded;
    final group = await groups.create(
      name: 'Reading club',
      memberIds: const [],
    );

    // Two widgets that both read the group before either edit landed: this is
    // the row each of them would have written back.
    final staleId = groups.byId(group.id)!.id;

    await groups.update(
      staleId,
      (current) => current.copyWith(maxSpeakerTurns: 2),
    );
    await groups.update(
      staleId,
      (current) => current.copyWith(name: 'Book club'),
    );

    final saved = groups.byId(group.id)!;
    expect(saved.name, 'Book club');
    expect(
      saved.speakerTurnLimit,
      2,
      reason: 'the rename must join the row, not replace it',
    );
  });

  test('an unchanged mutation writes nothing, including updatedAt', () async {
    final groups = providerFor(store);
    await groups.loaded;
    final group = await groups.create(
      name: 'Reading club',
      memberIds: const [],
    );
    final before = groups.byId(group.id)!.updatedAt;

    await groups.update(
      group.id,
      (current) => current.copyWith(name: 'Reading club'),
    );

    expect(groups.byId(group.id)!.updatedAt, before);
  });

  test('a stale write cannot resurrect a deleted group', () async {
    final groups = providerFor(store);
    await groups.loaded;
    final group = await groups.create(
      name: 'Reading club',
      memberIds: const [],
    );
    await groups.delete(group.id);

    // A rename that was in flight when the group went away — here, or on a peer
    // through LAN sync — must not put the row back.
    await groups.update(group.id, (current) => current.copyWith(name: 'Ghost'));

    expect(groups.byId(group.id), isNull);
    final reopened = providerFor(store);
    await reopened.loaded;
    expect(reopened.byId(group.id), isNull);
  });
}
