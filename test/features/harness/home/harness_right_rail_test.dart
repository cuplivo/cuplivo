import 'dart:typed_data';

import 'package:Cuplivo/features/harness/pages/home/harness_home_controller.dart';
import 'package:Cuplivo/features/harness/pages/home/harness_home_models.dart';
import 'package:Cuplivo/features/harness/pages/home/harness_right_rail.dart';
import 'package:Cuplivo/features/harness/pages/home/harness_session_catalog.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeWorkspaceFiles implements HarnessWorkspaceFiles {
  _FakeWorkspaceFiles({this.entries = const [], this.refuseText = false});

  final List<HarnessWorkspaceFileEntry> entries;
  final bool refuseText;
  int readTextCalls = 0;
  int readBytesCalls = 0;

  @override
  Future<HarnessWorkspaceFileListing> list(String path) async =>
      HarnessWorkspaceFileListing(path: path, entries: entries);

  @override
  Future<HarnessWorkspaceFileText> readText(String path) async {
    readTextCalls++;
    if (refuseText) {
      throw HarnessCatalogException(cause: 'binary or too large');
    }
    return HarnessWorkspaceFileText(path: path, text: 'hello');
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    readBytesCalls++;
    return Uint8List.fromList(const <int>[1, 2, 3]);
  }
}

const _session = HarnessSessionSummary(sessionId: 'session-1', title: 'One');

/// R7 is native: built-in cards, harvested plugin cards, the terminal hook and
/// the workspace-file preview hook.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpRail(
    WidgetTester tester, {
    HarnessRailPage page = HarnessRailPage.start,
    HarnessSessionSummary? session = _session,
    HarnessWorkspaceFiles? workspaceFiles,
    List<HarnessRailExtraEntry> extraEntries = const <HarnessRailExtraEntry>[],
    Widget Function(BuildContext, HarnessSessionSummary?)? terminalPanelBuilder,
    ValueChanged<HarnessWorkspaceFileEntry>? onPreviewWorkspaceFile,
    ValueChanged<HarnessRailPage>? onShowPage,
  }) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 380,
              height: 820,
              child: HarnessRightRail(
                page: page,
                session: session,
                workspaceFiles: workspaceFiles,
                onClose: () {},
                onToggleExpanded: () {},
                expanded: false,
                onShowPage: onShowPage ?? (_) {},
                onShowStart: () {},
                extraEntries: extraEntries,
                terminalPanelBuilder: terminalPanelBuilder,
                onPreviewWorkspaceFile: onPreviewWorkspaceFile,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  group('HarnessRailPage ids', () {
    test('equality is by id and a plugin page can carry a label', () {
      final changes = HarnessRailPage.plugin('changes', label: '代码变更');
      expect(changes.id, 'plugin:changes');
      expect(changes.label, '代码变更');
      expect(changes, HarnessRailPage.plugin('changes'));
      expect(changes, isNot(HarnessRailPage.start));
      expect(HarnessRailPage.start, isNot(HarnessRailPage.terminal));
    });
  });

  group('Start page', () {
    testWidgets('renders the built-in cards and extra harvested cards', (
      tester,
    ) async {
      var extraTapped = 0;
      await pumpRail(
        tester,
        extraEntries: [
          HarnessRailExtraEntry(
            id: '代码变更',
            title: '代码变更',
            icon: Lucide.Box,
            onTap: () => extraTapped++,
          ),
        ],
      );

      expect(find.byKey(const Key('dsh-rail-workspace-files')), findsOneWidget);
      expect(find.byKey(const Key('dsh-rail-new-terminal')), findsOneWidget);
      expect(find.byKey(const Key('dsh-rail-more-tools')), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('dsh-rail-entry-代码变更')),
        findsOneWidget,
      );
      expect(find.text('代码变更'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('dsh-rail-entry-代码变更')),
      );
      await tester.pump();
      expect(extraTapped, 1);
    });

    testWidgets('a built-in card navigates to its native page', (tester) async {
      final shown = <HarnessRailPage>[];
      await pumpRail(tester, onShowPage: shown.add);

      await tester.tap(find.byKey(const Key('dsh-rail-workspace-files')));
      await tester.pump();

      expect(shown, [HarnessRailPage.workspaceFiles]);
    });

    testWidgets('nothing harvested means no plugin section', (tester) async {
      await pumpRail(tester);
      expect(find.byKey(const Key('dsh-rail-more-tools')), findsOneWidget);
      expect(find.text('代码变更'), findsNothing);
    });
  });

  group('More-tools page', () {
    testWidgets('lists the same harvested cards', (tester) async {
      await pumpRail(
        tester,
        page: HarnessRailPage.moreTools,
        extraEntries: [
          HarnessRailExtraEntry(
            id: 'issue-与-pr',
            title: 'Issue 与 PR',
            icon: Lucide.Box,
            onTap: () {},
          ),
        ],
      );
      expect(
        find.byKey(const ValueKey<String>('dsh-rail-entry-issue-与-pr')),
        findsOneWidget,
      );
      expect(find.text('Issue 与 PR'), findsOneWidget);
    });
  });

  group('terminal seam', () {
    testWidgets('null builder keeps the honest placeholder', (tester) async {
      await pumpRail(tester, page: HarnessRailPage.terminal);
      expect(
        find.text('Remote terminals aren’t available in this build'),
        findsOneWidget,
      );
    });

    testWidgets('a builder replaces the placeholder with the panel', (
      tester,
    ) async {
      await pumpRail(
        tester,
        page: HarnessRailPage.terminal,
        terminalPanelBuilder: (context, session) =>
            Text('panel:${session?.sessionId}'),
      );
      expect(find.text('panel:session-1'), findsOneWidget);
      expect(
        find.text('Remote terminals aren’t available in this build'),
        findsNothing,
      );
    });
  });

  group('workspace-file preview seam', () {
    const pdf = HarnessWorkspaceFileEntry(
      name: 'report.pdf',
      path: 'docs/report.pdf',
      kind: HarnessFileKind.file,
    );
    const notes = HarnessWorkspaceFileEntry(
      name: 'notes.txt',
      path: 'notes.txt',
      kind: HarnessFileKind.file,
    );

    testWidgets('binary kinds go to the preview callback without a read', (
      tester,
    ) async {
      final files = _FakeWorkspaceFiles(entries: const [pdf, notes]);
      final previewed = <HarnessWorkspaceFileEntry>[];
      await pumpRail(
        tester,
        page: HarnessRailPage.workspaceFiles,
        workspaceFiles: files,
        onPreviewWorkspaceFile: previewed.add,
      );

      await tester.tap(find.text('report.pdf'));
      await tester.pump();

      expect(previewed, [pdf]);
      expect(files.readTextCalls, 0);
    });

    testWidgets('text files keep the rail preview', (tester) async {
      final files = _FakeWorkspaceFiles(entries: const [notes]);
      final previewed = <HarnessWorkspaceFileEntry>[];
      await pumpRail(
        tester,
        page: HarnessRailPage.workspaceFiles,
        workspaceFiles: files,
        onPreviewWorkspaceFile: previewed.add,
      );

      await tester.tap(find.text('notes.txt'));
      await tester.pump();
      await tester.pump();

      expect(files.readTextCalls, 1);
      expect(previewed, isEmpty);
      expect(find.text('hello'), findsOneWidget);
    });

    testWidgets('a refused text read is handed to the preview callback', (
      tester,
    ) async {
      final files = _FakeWorkspaceFiles(
        entries: const [notes],
        refuseText: true,
      );
      final previewed = <HarnessWorkspaceFileEntry>[];
      await pumpRail(
        tester,
        page: HarnessRailPage.workspaceFiles,
        workspaceFiles: files,
        onPreviewWorkspaceFile: previewed.add,
      );

      await tester.tap(find.text('notes.txt'));
      await tester.pump();
      await tester.pump();

      expect(files.readTextCalls, 1);
      expect(previewed, [notes]);
      // The rail is back on the listing for the page the host opens.
      expect(find.text('notes.txt'), findsOneWidget);
    });

    testWidgets('null callback keeps the pre-preview unavailable state', (
      tester,
    ) async {
      final files = _FakeWorkspaceFiles(
        entries: const [notes],
        refuseText: true,
      );
      await pumpRail(
        tester,
        page: HarnessRailPage.workspaceFiles,
        workspaceFiles: files,
      );

      await tester.tap(find.text('notes.txt'));
      await tester.pump();
      await tester.pump();

      expect(files.readTextCalls, 1);
      expect(find.text('This file can’t be previewed'), findsOneWidget);
    });
  });
}
