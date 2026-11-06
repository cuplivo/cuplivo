import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/database/business_data.dart';
import 'package:Cuplivo/core/database/kelivo_vocabulary.dart';
import 'package:Cuplivo/core/models/backup_scope.dart';
import 'package:Cuplivo/core/models/backup_target.dart';

/// Holds the reverse-import contract still true.
///
/// A Cuplivo backup carries two entity-keyed maps — `settings.json` and the
/// manifest's `businessEntityRowIds` — and a reader that meets a source key it
/// has no kind for does not ignore it: `BusinessSettingsRouter` throws
/// `FormatException` on the key, after every compatibility check on the archive
/// has already passed. `group_chats_v1` did exactly that to Kelivo v1.3.4.
///
/// So adding a business kind is not a storage decision, it is a decision about
/// which readers the archive is for. These tests make that decision unavoidable:
/// a new kind fails here until someone writes down what happens to it.
void main() {
  final pinned = KelivoVocabulary.v1_3_4;

  test('every business kind is readable by the pinned release or dispositioned', () {
    final unreadable = unreadableEntitySourceKeys(BackupTarget.kelivoV1_3_4);

    expect(
      unreadable,
      unreadableKindDispositions.keys.toSet(),
      reason:
          'A BusinessEntityKind that Kelivo v1.3.4 cannot read must be listed in '
          'unreadableKindDispositions with what its users lose. Adding a kind '
          'without an entry here is how #1052 shipped a backup no Kelivo build '
          'could restore (the manifest named group_chats_v1 and '
          'BusinessSettingsRouter threw on it), and no gate noticed.',
    );
  });

  test('an unreadable kind is an extension kind, so its rows can be dropped', () {
    // The sanitizer removes unreadable kinds from `extension_entity_rows`. A kind
    // stored in its own table would instead leave a table the older reader
    // rejects structurally, which is a different repair than this one.
    final unreadable = unreadableEntitySourceKeys(BackupTarget.kelivoV1_3_4);
    final extensionKinds = <String>{
      for (final kind in BusinessEntityKind.values)
        if (unreadable.contains(kind.sourceKey) && kind.extensionKind != null)
          kind.sourceKey,
    };
    expect(extensionKinds, unreadable);
  });

  test(
    'the pinned release reads every entity key this build writes minus the listed ones',
    () {
      final written = {
        for (final kind in BusinessEntityKind.values) kind.sourceKey,
      };
      expect(
        written.difference(pinned.entitySourceKeys),
        {'group_chats_v1'},
        reason:
            'Update KelivoVocabulary with a new frozen constant for a newer '
            'Kelivo release rather than editing v1_3_4 in place.',
      );
    },
  );

  test('the backup scope names only categories the pinned release declares', () {
    final declared = {
      for (final category in BackupCategory.values) category.name,
    };
    expect(
      declared.difference(pinned.categories),
      isEmpty,
      reason:
          'A new BackupCategory becomes a key of manifest["scope"]. That axis is '
          'tolerated by an older reader, so this is a pin rather than a gate — '
          'but an archive that names a category its reader cannot see is a claim '
          'the archive cannot keep.',
    );
  });

  test('a Kelivo-target export names no entity key that release lacks', () {
    const entityKeys = {'assistants_v1', 'group_chats_v1'};
    const otherKeys = {'selected_model_v1', 'display_theme_v1', 'scope'};

    final kept = withoutUnreadableEntityKeys(<String, Object>{
      for (final key in {...entityKeys, ...otherKeys}) key: key,
    }, BackupTarget.kelivoV1_3_4);

    expect(kept.keys, isNot(contains('group_chats_v1')));
    // Preference keys are not entity keys: they must survive untouched, or the
    // filter would silently empty a backup of everything that is not a row set.
    expect(kept.keys, containsAll(otherKeys));
    expect(kept.keys, contains('assistants_v1'));
  });

  test('this build keeps every key it writes', () {
    const keys = {'assistants_v1', 'group_chats_v1'};
    expect(
      withoutUnreadableEntityKeys(<String, Object>{
        for (final key in keys) key: key,
      }, BackupTarget.cuplivo).keys,
      containsAll(keys),
    );
  });
}
