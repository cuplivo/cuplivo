import 'dart:io';

import 'package:Cuplivo/core/providers/user_provider.dart';
import 'package:Cuplivo/utils/kelivo_file_uri.dart';
import 'package:Cuplivo/utils/sandbox_path_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/business_preferences_test_harness.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('user_avatar_canonical_');
    SandboxPathResolver.debugSetDirs(docsDir: temp.path);
  });

  tearDown(() async {
    SandboxPathResolver.debugSetDirs();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test(
    'a legacy absolute avatar value canonicalizes once and stays canonical',
    () async {
      final fixture = await BusinessPreferencesTestHarness.create();
      addTearDown(fixture.dispose);

      final legacyPath =
          '${temp.path.replaceAll('\\', '/')}/avatars/avatar_7.png';
      final first = await fixture.open();
      await first.preferences.setString('avatar_type', 'file');
      await first.preferences.setString('avatar_value', legacyPath);

      final user = UserProvider(preferences: first.preferences);
      addTearDown(user.dispose);
      await Future<void>.delayed(Duration.zero);

      expect(user.avatarType, 'file');
      expect(user.avatarValue, 'kelivo-file:///avatars/avatar_7.png');
      // The canonical form is persisted back…
      expect(
        first.preferences.getString('avatar_value'),
        'kelivo-file:///avatars/avatar_7.png',
      );
      await first.close();

      // …and a fresh provider must not decode it back into a host path.
      final reopened = await fixture.open();
      final restored = UserProvider(preferences: reopened.preferences);
      addTearDown(restored.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(KelivoFileUri.isKelivoFileUri(restored.avatarValue ?? ''), isTrue);
      expect(restored.avatarValue, 'kelivo-file:///avatars/avatar_7.png');
      expect(
        reopened.preferences.getString('avatar_value'),
        'kelivo-file:///avatars/avatar_7.png',
      );
    },
  );
}
