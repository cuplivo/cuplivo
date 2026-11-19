import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/database/extension_entity_store.dart';
import 'package:Cuplivo/core/models/chat_owner.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/chat_owners_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';

import '../../support/business_test_harness.dart';

/// A fake DSH connection provider: the real one needs a database and secure
/// storage, and this test only cares that a remote id is a live owner id.
class _FakeHarnessSource extends ChangeNotifier implements HarnessOwnerSource {
  _FakeHarnessSource(this.ids);

  final List<String> ids;

  @override
  Iterable<String> get harnessOwnerIds => ids;
}

/// A remote is an owner like an assistant or a group: it rides the same drag
/// order, it survives a restart through `chat_owner_order_v1`, and the
/// assistant-only paths keep ignoring it.
void main() {
  test(
    'a harness owner is listed, ordered and persisted beside the others',
    () async {
      final harness = await createBusinessTestHarness();
      final assistants = AssistantProvider(preferences: harness.preferences);
      await assistants.loaded;
      final a = await assistants.addAssistant(name: 'A');
      final b = await assistants.addAssistant(name: 'B');

      final groups = GroupChatProvider(
        store: ExtensionEntityStore(harness.database),
      );
      await groups.loaded;
      final group = await groups.create(name: 'G', memberIds: [a, b]);

      final remote = _FakeHarnessSource(['dsh-1']);
      final owners = ChatOwnersProvider(
        assistants: assistants,
        groups: groups,
        preferences: harness.preferences,
        harnesses: remote,
      );
      await owners.loaded;

      expect(owners.owners.map((owner) => owner.key), [
        ChatOwner.assistant(a).key,
        ChatOwner.assistant(b).key,
        ChatOwner.group(group.id).key,
        ChatOwner.harness('dsh-1').key,
      ]);

      // A remote has no tag header: `ungroupedOwners` keeps it even when every
      // assistant is tagged, because tags only ever file assistants away.
      expect(owners.ungroupedOwners({a, b}).map((owner) => owner.key), [
        ChatOwner.group(group.id).key,
        ChatOwner.harness('dsh-1').key,
      ]);

      // Drag the remote to the very top: the shared order accepts a mixed list.
      await owners.reorder(3, 0);
      expect(owners.owners.first, const ChatOwner.harness('dsh-1'));

      // The prefixed key is what the preference channel stores, so a restart
      // resolves it again without knowing anything about DSH.
      final reopened = ChatOwnersProvider(
        assistants: assistants,
        groups: groups,
        preferences: harness.preferences,
        harnesses: remote,
      );
      await reopened.loaded;
      expect(reopened.owners.first, const ChatOwner.harness('dsh-1'));
      expect(
        harness.preferences.getStringList(ChatOwnersProvider.preferenceKey),
        contains('harness:dsh-1'),
      );
    },
  );

  test(
    'a deleted remote’s order slot is dropped without a source row',
    () async {
      final harness = await createBusinessTestHarness();
      final assistants = AssistantProvider(preferences: harness.preferences);
      await assistants.loaded;
      final a = await assistants.addAssistant(name: 'A');
      final groups = GroupChatProvider(
        store: ExtensionEntityStore(harness.database),
      );
      await groups.loaded;

      final source = _FakeHarnessSource(['dsh-1', 'dsh-2']);
      final owners = ChatOwnersProvider(
        assistants: assistants,
        groups: groups,
        preferences: harness.preferences,
        harnesses: source,
      );
      await owners.loaded;
      expect(
        owners.owners
            .where((owner) => owner.isHarness)
            .map((owner) => owner.id),
        ['dsh-1', 'dsh-2'],
      );

      // Deleting one record removes it from the list on the source's
      // notification; the other keeps its place.
      source.ids.remove('dsh-1');
      source.notifyListeners();
      await Future<void>.delayed(Duration.zero);
      expect(
        owners.owners
            .where((owner) => owner.isHarness)
            .map((owner) => owner.id),
        ['dsh-2'],
      );
      // An assistant path never sees the remote as an assistant.
      expect(
        owners
            .inOwnerOrder(
              assistants.assistants,
              (assistant) => ChatOwner.assistant(assistant.id).key,
            )
            .map((assistant) => assistant.id),
        [a],
      );
    },
  );
}
