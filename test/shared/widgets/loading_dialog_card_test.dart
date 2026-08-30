import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/backup/data_sync.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/loading_dialog_card.dart';

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  group('LoadingDialogCard', () {
    testWidgets('renders activity indicator without label', (tester) async {
      await tester.pumpWidget(_host(const LoadingDialogCard()));

      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('renders optional label text', (tester) async {
      await tester.pumpWidget(_host(const LoadingDialogCard(label: '正在加载')));

      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(find.text('正在加载'), findsOneWidget);
    });

    testWidgets(
      'elapsedTextBuilder ticks every second and cancels on dispose',
      (tester) async {
        await tester.pumpWidget(
          _host(
            LoadingDialogCard(
              label: 'Exporting',
              elapsedTextBuilder: _tickLabel,
            ),
          ),
        );
        await tester.pump();
        expect(find.text('tick 0'), findsOneWidget);
        expect(find.text('Exporting'), findsOneWidget);

        await tester.pump(const Duration(seconds: 1));
        expect(find.text('tick 1'), findsOneWidget);

        await tester.pump(const Duration(seconds: 1));
        expect(find.text('tick 2'), findsOneWidget);

        // Unmount — dispose must cancel the periodic timer, otherwise the test
        // framework reports a pending Timer.
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('without elapsedTextBuilder no timer and no elapsed line', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const LoadingDialogCard(label: 'Hi')));
      await tester.pump();
      expect(find.text('Hi'), findsOneWidget);
      expect(find.textContaining('tick'), findsNothing);
    });

    testWidgets('labelListenable wins over static label and updates live', (
      tester,
    ) async {
      final label = ValueNotifier<String>('stage one');
      await tester.pumpWidget(
        _host(LoadingDialogCard(label: 'static', labelListenable: label)),
      );
      await tester.pump();
      expect(find.text('stage one'), findsOneWidget);
      expect(find.text('static'), findsNothing);

      label.value = 'stage two';
      await tester.pump();
      expect(find.text('stage two'), findsOneWidget);
      expect(find.text('stage one'), findsNothing);

      label.dispose();
    });
  });

  group('LoadingDialogCard progressListenable', () {
    testWidgets('renders stage + indeterminate bar for extracting', (
      tester,
    ) async {
      final progress = ValueNotifier<RestoreProgress>(
        const RestoreProgress(stage: RestoreStage.extracting),
      );
      await tester.pumpWidget(
        _host(LoadingDialogCard(progressListenable: progress)),
      );
      await tester.pump();

      expect(
        find.text('Extracting data...'),
        findsOneWidget,
        reason:
            'neutralized lanSyncRestoreExtracting copy shared with LAN sync',
      );
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, isNull);

      progress.dispose();
    });

    testWidgets('updates live and shows counts for mergingChats', (
      tester,
    ) async {
      final progress = ValueNotifier<RestoreProgress>(
        const RestoreProgress(stage: RestoreStage.extracting),
      );
      await tester.pumpWidget(
        _host(LoadingDialogCard(progressListenable: progress)),
      );
      await tester.pump();
      expect(find.text('Merging chats...'), findsNothing);

      progress.value = const RestoreProgress(
        stage: RestoreStage.mergingChats,
        conversationsMerged: 3,
        conversationsTotal: 10,
      );
      await tester.pump();
      expect(find.text('Merging chats...'), findsOneWidget);
      expect(find.text('3/10 conversations'), findsOneWidget);

      progress.dispose();
    });

    testWidgets('shows file count line during copyingFiles', (tester) async {
      final progress = ValueNotifier<RestoreProgress>(
        const RestoreProgress(
          stage: RestoreStage.copyingFiles,
          filesCopied: 2,
          filesTotal: 5,
          bytesTotal: 1000,
        ),
      );
      await tester.pumpWidget(
        _host(LoadingDialogCard(progressListenable: progress)),
      );
      await tester.pump();

      expect(find.text('Writing files...'), findsOneWidget);
      expect(find.text('2/5 files · 1000 B'), findsOneWidget);

      progress.dispose();
    });
  });
}

String _tickLabel(int seconds) => 'tick $seconds';
