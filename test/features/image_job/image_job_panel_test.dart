import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/image_job/models/image_job.dart';
import 'package:Cuplivo/features/image_job/services/image_model_resolver.dart';
import 'package:Cuplivo/features/image_job/widgets/image_job_panel.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';

import '../../support/business_test_harness.dart';

ImageJob _job({
  ImageJobState state = ImageJobState.running,
  DateTime? startedAt,
  DateTime? finishedAt,
  String? requestedRatio,
}) {
  final start = startedAt ?? DateTime(2026, 11, 17, 12, 0, 0);
  return ImageJob(
    id: 'job-1',
    conversationId: 'c1',
    messageId: 'm1',
    toolCallId: 't1',
    idempotencyKey: 'key-1',
    prompt: '霓虹雨夜的旧书店',
    aspectRatio: requestedRatio,
    assetId: 'img_abc',
    uri: '/tmp/img_abc.png',
    state: state,
    createdAt: start,
    startedAt: start,
    finishedAt: finishedAt,
  );
}

ImagePart _part({
  ImagePartState? state = ImagePartState.pending,
  String? prompt = '霓虹雨夜的旧书店',
  int? durationMs,
}) {
  return ImagePart(
    uri: '/tmp/img_abc.png',
    assetId: 'img_abc',
    jobId: 'job-1',
    state: state,
    prompt: prompt,
    model: 'openai::gpt-image-1',
    durationMs: durationMs,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsProvider settings;

  setUp(() async {
    settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
  });

  Future<AppLocalizations> pumpBody(
    WidgetTester tester,
    ImageJobPanelData data,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          // The app's toast host, wrapped around the shell the way the real app
          // does it — inside MaterialApp, so it has a Directionality.
          builder: (context, child) =>
              AppSnackBarOverlay(child: child ?? const SizedBox.shrink()),
          home: Scaffold(
            // Deliberately not wrapped in a scroll view: the body has to survive
            // a bare Scaffold the way it survives the real shell, or the harness
            // hides the overflow the desktop dialog used to have.
            body: ImageJobPanelBody(data: data),
          ),
        ),
      ),
    );
    await tester.pump();
    return AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
  }

  testWidgets('a running picture is read-only: nothing to press but 复制', (
    tester,
  ) async {
    final l10n = await pumpBody(
      tester,
      ImageJobPanelData(
        part: _part(),
        job: _job(),
        binding: const ModelBinding(
          providerId: 'openai',
          modelId: 'gpt-image-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('霓虹雨夜的旧书店'), findsOneWidget);
    expect(find.text('gpt-image-1'), findsOneWidget);
    // An illustration is an accessory: there is no 编辑, no 取消 and no 重新生成.
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.text(l10n.imageJobPanelCopy), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('a finished picture shows its time and stays read-only', (
    tester,
  ) async {
    final started = DateTime(2026, 11, 17, 12, 0, 0);
    final l10n = await pumpBody(
      tester,
      ImageJobPanelData(
        part: _part(state: null),
        job: _job(
          state: ImageJobState.completed,
          startedAt: started,
          finishedAt: started.add(const Duration(milliseconds: 12600)),
        ),
        binding: const ModelBinding(
          providerId: 'openai',
          modelId: 'gpt-image-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('12.6s'), findsOneWidget);
    expect(find.text(l10n.imageJobPanelCopy), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    // Usage belongs below 用时: it is a picture count today and a token count
    // soon, and the header has no room for a value that changes shape.
    expect(find.text(l10n.imageJobPanelUsageLabel), findsOneWidget);
    expect(find.text(l10n.imageJobPanelOneImage), findsOneWidget);
  });

  testWidgets('copying the prompt confirms it like every other copy', (
    tester,
  ) async {
    // The clipboard channel has no host in a widget test, so answer it here.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final l10n = await pumpBody(tester, ImageJobPanelData(part: _part()));
    await tester.pumpAndSettle();

    final copy = find.text(l10n.imageJobPanelCopy);
    await tester.ensureVisible(copy);
    await tester.tap(copy);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The app's own toast, wrapped around the shell like the app does.
    expect(find.text(l10n.chatMessageWidgetCopiedToClipboard), findsOneWidget);

    // Let the toast's own dismissal timer run out, or teardown trips on it.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('a part from a previous run still names its model and prompt', (
    tester,
  ) async {
    // No job: the app restarted. The part is the only witness, so the panel
    // must not go blank.
    await pumpBody(
      tester,
      ImageJobPanelData(part: _part(state: ImagePartState.interrupted)),
    );
    await tester.pumpAndSettle();

    expect(find.text('gpt-image-1'), findsOneWidget);
    expect(find.text('霓虹雨夜的旧书店'), findsOneWidget);
  });

  testWidgets('a restored picture still shows how long it took', (
    tester,
  ) async {
    // The duration lives on the part exactly so it survives a restart; reading
    // the live job unconditionally dropped 用时 for every picture drawn in an
    // earlier session, while the card header kept showing it.
    final l10n = await pumpBody(
      tester,
      ImageJobPanelData(part: _part(state: null, durationMs: 12600)),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.imageJobPanelElapsedLabel), findsOneWidget);
    expect(find.text('12.6s'), findsOneWidget);
  });

  testWidgets(
    'the desktop dialog scrolls a long prompt instead of overflowing',
    (tester) async {
      // The phone shell has always scrolled. The desktop one wrapped the same
      // unbounded column in a Dialog with no ceiling, so a long prompt painted
      // past the window. This opens the real shell, not the body.
      tester.view.physicalSize = const Size(1400, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final longPrompt = '很长的提示词。' * 400;
      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsProvider>.value(
          value: settings,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) =>
                AppSnackBarOverlay(child: child ?? const SizedBox.shrink()),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showImageJobPanel(
                      context,
                      ImageJobPanelData(part: _part(prompt: longPrompt)),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final scrollable = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(Scrollable),
      );
      expect(scrollable, findsOneWidget);
      // Reachable, not merely unbounded: there is something to scroll.
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.maxScrollExtent, greaterThan(0));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('the model row prefers the configured name over the raw id', () {
    expect(
      imageModelDisplayName(
        settings,
        const ModelBinding(providerId: 'openai', modelId: 'gpt-image-1'),
      ),
      'gpt-image-1',
    );
    expect(imageModelDisplayName(settings, null), '—');
    expect(
      imageModelDisplayName(settings, null, fallbackKey: 'openai::gpt-image-1'),
      'gpt-image-1',
    );
  });
}
