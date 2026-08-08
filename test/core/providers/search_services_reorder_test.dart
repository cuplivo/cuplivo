import 'dart:convert';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/search/search_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for SettingsProvider condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  Future<SettingsProvider> buildLoaded(
    List<SearchServiceOptions> services,
  ) async {
    SharedPreferences.setMockInitialValues({
      'search_services_v1': jsonEncode(
        services.map((e) => e.toJson()).toList(),
      ),
    });
    final settings = SettingsProvider();
    await _waitUntil(() => settings.searchServices.length == services.length);
    return settings;
  }

  test(
    'reorderSearchServices moves the item and keeps selection by id',
    () async {
      final settings = await buildLoaded([
        BingLocalOptions(id: 'a'),
        BingLocalOptions(id: 'b'),
        BingLocalOptions(id: 'c'),
      ]);
      await settings.setSearchServiceSelected(2);

      await settings.reorderSearchServices(2, 0);

      expect(settings.searchServices.map((e) => e.id).toList(), [
        'c',
        'a',
        'b',
      ]);
      // The previously selected service (c) moved with the row.
      expect(settings.searchServiceSelected, 0);
    },
  );

  test(
    'reorderSearchServices moves an item down and keeps selection attached',
    () async {
      final settings = await buildLoaded([
        BingLocalOptions(id: 'a'),
        BingLocalOptions(id: 'b'),
        BingLocalOptions(id: 'c'),
      ]);
      await settings.setSearchServiceSelected(0);

      await settings.reorderSearchServices(0, 2);

      expect(settings.searchServices.map((e) => e.id).toList(), [
        'b',
        'c',
        'a',
      ]);
      // The selected service (a) moved to the end, so selection follows it.
      expect(settings.searchServiceSelected, 2);
    },
  );

  test('reorderSearchServices keeps selection by id when a non-selected row '
      'is moved across it', () async {
    final settings = await buildLoaded([
      BingLocalOptions(id: 'a'),
      BingLocalOptions(id: 'b'),
      BingLocalOptions(id: 'c'),
    ]);
    await settings.setSearchServiceSelected(1);

    await settings.reorderSearchServices(0, 2);

    expect(settings.searchServices.map((e) => e.id).toList(), ['b', 'c', 'a']);
    // Selection stays attached to service b, whose index moved to 0.
    expect(settings.searchServiceSelected, 0);
  });

  test('reorderSearchServices persists the new order and selection', () async {
    final settings = await buildLoaded([
      BingLocalOptions(id: 'a'),
      BingLocalOptions(id: 'b'),
      BingLocalOptions(id: 'c'),
    ]);
    await settings.setSearchServiceSelected(1);

    await settings.reorderSearchServices(0, 2);

    // Reload from the same mocked prefs with a fresh provider.
    final prefs = await SharedPreferences.getInstance();
    final savedServices = prefs.getString('search_services_v1')!;
    final savedSelected = prefs.getInt('search_selected_v1')!;
    SharedPreferences.setMockInitialValues({
      'search_services_v1': savedServices,
      'search_selected_v1': savedSelected,
    });
    final reloaded = SettingsProvider();
    addTearDown(reloaded.dispose);
    await _waitUntil(() => reloaded.searchServices.length == 3);

    expect(reloaded.searchServices.map((e) => e.id).toList(), ['b', 'c', 'a']);
    expect(reloaded.searchServiceSelected, 0);
  });

  test(
    'reorderSearchServices ignores invalid source and negative indices',
    () async {
      final settings = await buildLoaded([
        BingLocalOptions(id: 'a'),
        BingLocalOptions(id: 'b'),
        BingLocalOptions(id: 'c'),
      ]);
      await settings.setSearchServiceSelected(1);

      await settings.reorderSearchServices(-1, 1);
      expect(settings.searchServices.map((e) => e.id).toList(), [
        'a',
        'b',
        'c',
      ]);
      expect(settings.searchServiceSelected, 1);

      await settings.reorderSearchServices(0, -1);
      expect(settings.searchServices.map((e) => e.id).toList(), [
        'a',
        'b',
        'c',
      ]);
      expect(settings.searchServiceSelected, 1);

      await settings.reorderSearchServices(5, 0);
      expect(settings.searchServices.map((e) => e.id).toList(), [
        'a',
        'b',
        'c',
      ]);
      expect(settings.searchServiceSelected, 1);
    },
  );

  test('reorderSearchServices ignores out-of-range indices', () async {
    final settings = await buildLoaded([
      BingLocalOptions(id: 'a'),
      BingLocalOptions(id: 'b'),
    ]);

    await settings.reorderSearchServices(0, 5);

    expect(settings.searchServices.map((e) => e.id).toList(), ['a', 'b']);
  });

  test('reorderSearchServices is a no-op when indices are equal', () async {
    final settings = await buildLoaded([
      BingLocalOptions(id: 'a'),
      BingLocalOptions(id: 'b'),
    ]);

    await settings.reorderSearchServices(1, 1);

    expect(settings.searchServices.map((e) => e.id).toList(), ['a', 'b']);
  });
}
