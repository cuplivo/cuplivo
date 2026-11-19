/// Fixtures shared by the Android E2E acceptance scenarios.
///
/// A scenario boots the production entry point, so every path it writes has to
/// point at a disposable directory and the Drift database it opens has to be
/// seeded first: acceptance must not depend on onboarding, network access,
/// credentials or state left by an earlier run.
library;

import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
// The fixture path provider is a dev dependency, as in the other device tests.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// The conversation an acceptance scenario opens first.
const String e2ePrimaryConversationTitle = 'E2E acceptance';

/// Disposable application directories for the production app under test.
///
/// `path_provider` reaches the platform through this interface, so replacing
/// the instance before `main()` keeps the app's data, cache and temp trees
/// inside [root] and leaves the device's real app data untouched.
class E2eFixturePaths extends PathProviderPlatform {
  E2eFixturePaths(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

/// Creates and seeds the database the production app will open from [root].
///
/// Keep this as the single place that describes the acceptance fixture: every
/// scenario shares it, so a screen starts from the same deterministic state.
Future<void> seedE2eDatabase(
  Directory root, {
  String appLocale = 'en_US',
}) async {
  final database = AppDatabase.open(
    file: File('${root.path}/${AppDatabase.databaseFileName}'),
  );
  final repository = ChatDatabaseRepository(database);
  await repository.ensureReady();
  try {
    final business = BusinessRepository(database);
    await business.writeMigrationReceipt();
    // Deterministic first frame: light, conversation-first home. The locale
    // follows the scenario: review screenshots use the reference language.
    await business.setPreference('display_new_chat_on_launch_v1', false);
    await business.setPreference('theme_mode_v1', 'light');
    await business.setPreference('app_locale_v1', appLocale);
    await business.setPreference('use_dynamic_color_v1', false);
    // Both checks fire after the first frame and make real network calls;
    // they must not run during a hermetic acquisition run.
    await business.setPreference('display_show_app_updates_v1', false);
    await business.setPreference('model_catalog_auto_update_v1', false);
    // Microseconds since the epoch, like MicrosecondDateTimeConverter. A
    // believable date keeps the review screenshots free of 1970 timestamps.
    await database.customStatement('''
INSERT INTO conversation_rows(id,title,created_at,updated_at) VALUES
  ('e2e-home','$e2ePrimaryConversationTitle',1794999000000000,1795000100000000),
  ('e2e-second','Second conversation',1794998000000000,1794999900000000),
  ('e2e-third','Third conversation',1794997000000000,1794999800000000)
''');
    await database.customStatement('''
INSERT INTO message_rows(id,conversation_id,role,timestamp,message_order) VALUES
  ('e2e-u1','e2e-home','user',1795000000000000,0),
  ('e2e-a1','e2e-home','assistant',1795000060000000,1),
  ('e2e-u2','e2e-second','user',1794999800000000,0),
  ('e2e-u3','e2e-third','user',1794999700000000,0)
''');
    await database.customStatement('''
INSERT INTO message_part_rows(conversation_id,revision_id,ordinal,kind,payload,created_at,updated_at) VALUES
  ('e2e-home','e2e-u1',0,'text','Walk me through the **UI acceptance** flow.',1795000000000000,1795000000000000),
  ('e2e-home','e2e-a1',0,'text','## Rendering sample

- **Bold**, *italic* and `inline code`
- A list item with `inline code`

> A quote block.

```dart
final answer = 42;
```
',1795000060000000,1795000060000000),
  ('e2e-second','e2e-u2',0,'text','A second conversation gives the drawer a list.',1794999800000000,1794999800000000),
  ('e2e-third','e2e-u3',0,'text','A third conversation keeps the list scrollable.',1794999700000000,1794999700000000)
''');
    await database.customSelect('PRAGMA wal_checkpoint(TRUNCATE)').get();
  } finally {
    await repository.close();
  }
}
