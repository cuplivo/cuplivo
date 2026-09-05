import 'dart:io';

import 'package:Cuplivo/core/models/workspace.dart';
import 'package:Cuplivo/features/workspace/widgets/workspace_terminal_persistence_section.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Workspace _workspace({bool keep = false}) => Workspace(
  id: 'workspace-a',
  displayName: 'Workspace',
  alias: 'workspace-a',
  keepTerminalAfterExit: keep,
);

Future<void> _pumpSection(
  WidgetTester tester, {
  required Workspace workspace,
  required bool expanded,
}) => tester.pumpWidget(
  MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: WorkspaceTerminalPersistenceSection(
        workspace: workspace,
        expanded: expanded,
        busy: false,
        onToggle: () {},
        onKeepChanged: (_) {},
        onDurableChanged: (_) {},
        onAutoStartChanged: (_) {},
      ),
    ),
  ),
);

void main() {
  testWidgets('section starts collapsed and exposes the requested title', (
    tester,
  ) async {
    await _pumpSection(tester, workspace: _workspace(), expanded: false);

    expect(find.text('沙箱与终端持久化设置'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('workspace-terminal-keep-row')),
      findsNothing,
    );
  });

  testWidgets('expanded rows keep the required order and child gating', (
    tester,
  ) async {
    await _pumpSection(tester, workspace: _workspace(), expanded: true);

    final keepRow = find.byKey(
      const ValueKey<String>('workspace-terminal-keep-row'),
    );
    final durableRow = find.byKey(
      const ValueKey<String>('workspace-terminal-durable-row'),
    );
    final autoRow = find.byKey(
      const ValueKey<String>('workspace-terminal-auto-start-row'),
    );
    expect(keepRow, findsOneWidget);
    expect(durableRow, findsOneWidget);
    expect(autoRow, findsOneWidget);
    expect(
      tester.getTopLeft(keepRow).dy,
      lessThan(tester.getTopLeft(durableRow).dy),
    );
    expect(
      tester.getTopLeft(durableRow).dy,
      lessThan(tester.getTopLeft(autoRow).dy),
    );

    final keepSwitch = tester.widget<IosSwitch>(
      find.descendant(of: keepRow, matching: find.byType(IosSwitch)),
    );
    final durableSwitch = tester.widget<IosSwitch>(
      find.descendant(of: durableRow, matching: find.byType(IosSwitch)),
    );
    final autoSwitch = tester.widget<IosSwitch>(
      find.descendant(of: autoRow, matching: find.byType(IosSwitch)),
    );
    expect(keepSwitch.onChanged, isNotNull);
    expect(durableSwitch.onChanged, isNull);
    expect(autoSwitch.onChanged, isNull);

    await _pumpSection(
      tester,
      workspace: _workspace(keep: true),
      expanded: true,
    );
    expect(
      tester
          .widget<IosSwitch>(
            find.descendant(of: durableRow, matching: find.byType(IosSwitch)),
          )
          .onChanged,
      isNotNull,
    );
    expect(
      tester
          .widget<IosSwitch>(
            find.descendant(of: autoRow, matching: find.byType(IosSwitch)),
          )
          .onChanged,
      isNotNull,
    );
  });

  test('workspace detail keeps Android gates and section placement', () {
    final source = File(
      'lib/features/workspace/pages/workspace_detail_page.dart',
    ).readAsStringSync();
    final installIndex = source.indexOf('title: l10n.workspaceInstallDeps');
    final persistenceIndex = source.indexOf(
      'WorkspaceTerminalPersistenceSection(',
    );
    final sandboxIndex = source.indexOf(
      'title: l10n.workspaceSandboxDirEntryTitle',
    );

    expect(source, contains('if (Platform.isAndroid)'));
    expect(source, contains('if (Platform.isAndroid) ...['));
    expect(installIndex, greaterThanOrEqualTo(0));
    expect(persistenceIndex, greaterThan(installIndex));
    expect(sandboxIndex, greaterThan(persistenceIndex));
  });
}
