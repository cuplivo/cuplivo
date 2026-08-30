import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsProvider desktop width persistence', () {
    test('loads persisted sidebar widths and open states', () async {
      final businessPrefs = BusinessPreferences.memoryForTests({
        'desktop_sidebar_width_v1': 352.0,
        'desktop_sidebar_open_v1': false,
        'desktop_right_sidebar_width_v1': 342.0,
        'desktop_right_sidebar_open_v1': true,
      });
      final settings = SettingsProvider(preferences: businessPrefs);

      await settings.loaded;

      expect(settings.desktopSidebarWidth, 352.0);
      expect(settings.desktopSidebarOpen, isFalse);
      expect(settings.desktopRightSidebarWidth, 342.0);
      expect(settings.desktopRightSidebarOpen, isTrue);
    });

    test('persists widths across a simulated restart', () async {
      final businessPrefs = BusinessPreferences.memoryForTests({
        'desktop_sidebar_width_v1': 300.0,
        'desktop_right_sidebar_width_v1': 300.0,
      });
      final first = SettingsProvider(preferences: businessPrefs);
      await first.loaded;

      await first.setDesktopSidebarWidth(352);
      await first.setDesktopRightSidebarWidth(330);

      final second = SettingsProvider(preferences: businessPrefs);
      await second.loaded;

      expect(second.desktopSidebarWidth, 352.0);
      expect(second.desktopRightSidebarWidth, 330.0);
    });

    test('persists sidebar open state across a simulated restart', () async {
      final businessPrefs = BusinessPreferences.memoryForTests();
      final first = SettingsProvider(preferences: businessPrefs);
      await first.loaded;

      await first.setDesktopRightSidebarOpen(false);
      await first.setDesktopSidebarOpen(false);

      final second = SettingsProvider(preferences: businessPrefs);
      await second.loaded;

      expect(second.desktopRightSidebarOpen, isFalse);
      expect(second.desktopSidebarOpen, isFalse);
    });
  });
}
