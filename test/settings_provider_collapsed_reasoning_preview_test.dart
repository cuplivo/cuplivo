import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';

import 'support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'collapsed reasoning preview defaults on and persists changes',
    () async {
      final settings = await createBusinessTestPreferences();

      expect(settings.showCollapsedReasoningPreview, isTrue);

      await settings.setShowCollapsedReasoningPreview(false);
      expect(settings.showCollapsedReasoningPreview, isFalse);
      expect(
        businessPrefs.getBool('display_show_collapsed_reasoning_preview_v1'),
        isFalse,
      );

      final reloaded = SettingsProvider(preferences: businessPrefs);
      await reloaded.loaded;
      expect(reloaded.showCollapsedReasoningPreview, isFalse);
    },
  );
}
