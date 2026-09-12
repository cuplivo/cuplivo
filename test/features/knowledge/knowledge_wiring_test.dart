import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mobile settings exposes the knowledge entry after World Book', () {
    final source = File(
      'lib/features/settings/pages/settings_page.dart',
    ).readAsStringSync();
    expect(source, contains('KnowledgePage()'));
    expect(source, contains('l10n.knowledgePageTitle'));

    final worldBook = source.indexOf('WorldBookPage()');
    final knowledge = source.indexOf('KnowledgePage()');
    expect(worldBook, greaterThan(-1));
    expect(knowledge, greaterThan(worldBook));
  });

  test('desktop settings registers the knowledge pane', () {
    final source = File(
      'lib/desktop/desktop_settings_page.dart',
    ).readAsStringSync();
    expect(source, contains('_SettingsMenuItem.knowledgeBase'));
    expect(source, contains('DesktopKnowledgePane'));
    expect(source, contains('l10n.knowledgePageTitle'));
  });

  test('desktop drop targets are gated by the active shell tab', () {
    final home = File(
      'lib/features/home/pages/home_page.dart',
    ).readAsStringSync();
    expect(
      home,
      contains('DesktopTabBus.instance.index == DesktopTabBus.chat'),
    );

    final pane = File(
      'lib/desktop/setting/knowledge_pane.dart',
    ).readAsStringSync();
    expect(pane, contains('DropTarget('));
    expect(
      pane,
      contains('DesktopTabBus.instance.index == DesktopTabBus.settings'),
    );

    final shell = File('lib/desktop/desktop_home_page.dart').readAsStringSync();
    expect(shell, contains('DesktopTabBus.instance.setIndex'));
  });
}
