import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';

Future<void> _waitForSettingsLoad() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsProvider chat rendering engine', () {
    test('defaults to native and treats unknown values as native', () async {
      for (final initialValues in <Map<String, Object>>[
        const {},
        const {'display_chat_rendering_engine_v1': 'unknown'},
      ]) {
        SharedPreferences.setMockInitialValues(initialValues);
        final settings = SettingsProvider();
        addTearDown(settings.dispose);

        await _waitForSettingsLoad();

        expect(settings.chatRenderingEngine, ChatRenderingEngine.native);
      }
    });

    test('loads every persisted engine value', () async {
      const cases = <String, ChatRenderingEngine>{
        'native': ChatRenderingEngine.native,
        'webView': ChatRenderingEngine.webView,
      };

      for (final entry in cases.entries) {
        SharedPreferences.setMockInitialValues({
          'display_chat_rendering_engine_v1': entry.key,
        });
        final settings = SettingsProvider();
        addTearDown(settings.dispose);

        await _waitForSettingsLoad();

        expect(settings.chatRenderingEngine, entry.value);
      }
    });

    test('persists changes and preserves them in copyWith', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      addTearDown(settings.dispose);
      await _waitForSettingsLoad();

      await settings.setChatRenderingEngine(ChatRenderingEngine.webView);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('display_chat_rendering_engine_v1'), 'webView');
      final copy = settings.copyWith();
      addTearDown(copy.dispose);
      expect(copy.chatRenderingEngine, ChatRenderingEngine.webView);
    });
  });
}
