import "../../../support/business_test_harness.dart";
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tts_provider.dart';
import 'package:Cuplivo/desktop/setting/tts_services_pane.dart';
import 'package:Cuplivo/features/settings/pages/tts_services_page.dart';
import 'package:Cuplivo/features/settings/widgets/voice_service_widgets.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ttsChannel = MethodChannel('flutter_tts');
  const audioGlobalChannel = MethodChannel('xyz.luan/audioplayers.global');
  const audioChannel = MethodChannel('xyz.luan/audioplayers');

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, (call) async {
          switch (call.method) {
            case 'getLanguages':
              return const <String>['en-US'];
            case 'getEngines':
              return const <String>['test-tts'];
            case 'isLanguageAvailable':
              return true;
            default:
              return null;
          }
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioGlobalChannel, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioChannel, (_) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioGlobalChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioChannel, null);
  });

  testWidgets('mobile add network TTS opens a full page editor', (
    tester,
  ) async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    final tts = TtsProvider(preferences: createBusinessTestPreferences());
    addTearDown(tts.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<TtsProvider>.value(value: tts),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: TtsServicesPage(),
        ),
      ),
    );

    final settingsActionY = tester.getCenter(find.byTooltip('TTS settings')).dy;
    final ttsAddY = tester.getCenter(find.byTooltip('Add')).dy;
    final asrAddY = tester
        .getCenter(find.byTooltip('Add speech recognition service'))
        .dy;
    expect(ttsAddY, greaterThan(settingsActionY + 20));
    expect(asrAddY, greaterThan(ttsAddY));

    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();

    expect(find.text('Add TTS Service'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('OpenAI'), findsWidgets);
    expect(find.text('xAI'), findsOneWidget);

    await tester.tap(find.text('xAI'));
    await tester.pumpAndSettle();

    expect(find.text('Model'), findsNothing);
    expect(find.text('Language'), findsOneWidget);

    await tester.tap(find.text('Azure'));
    await tester.pumpAndSettle();

    expect(find.text('Model'), findsNothing);
    expect(find.text('Language'), findsOneWidget);
  });

  testWidgets('mobile TTS settings button opens playback settings', (
    tester,
  ) async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    final tts = TtsProvider(preferences: createBusinessTestPreferences());
    addTearDown(tts.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<TtsProvider>.value(value: tts),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: TtsServicesPage(),
        ),
      ),
    );

    await tester.tap(find.byTooltip('TTS settings'));
    await tester.pumpAndSettle();

    expect(find.text('TTS Settings'), findsOneWidget);
    expect(find.text('Auto-play Assistant Replies'), findsOneWidget);
    expect(find.text('Reuse Audio for Replay'), findsOneWidget);
    expect(find.text('Text Selection'), findsOneWidget);
  });

  testWidgets('mobile TTS editor exposes provider advanced fields', (
    tester,
  ) async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    final tts = TtsProvider(preferences: createBusinessTestPreferences());
    addTearDown(tts.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<TtsProvider>.value(value: tts),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: TtsServicesPage(),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('MiniMax'));
    await tester.pumpAndSettle();
    expect(find.text('Auto match'), findsOneWidget);
    expect(find.text('Volume'), findsOneWidget);
    expect(find.text('Language boost'), findsOneWidget);
    expect(find.text('Generate subtitles'), findsNothing);
    expect(find.text('whisper'), findsNothing);
    expect(find.text('flac'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);

    await tester.tap(find.text('Qwen Audio'));
    await tester.pumpAndSettle();
    expect(find.text('Workspace ID'), findsOneWidget);
    expect(find.text('Region'), findsOneWidget);
    expect(find.text('Audio format'), findsOneWidget);

    final regionField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.controller?.text == 'cn-beijing',
    );
    expect(regionField, findsOneWidget);
    expect(
      tester.getTopLeft(regionField).dy,
      greaterThan(tester.getBottomLeft(find.text('Region')).dy),
    );
    expect(
      tester.getTopLeft(regionField).dx,
      closeTo(tester.getTopLeft(find.text('Region')).dx, 1),
    );

    final audioFormatRow = find.byWidgetPredicate(
      (widget) =>
          widget is VoiceServiceMobileSelectRow<String> &&
          widget.label == 'Audio format',
    );
    final selectedMp3 = find.descendant(
      of: audioFormatRow,
      matching: find.text('mp3'),
    );
    expect(audioFormatRow, findsOneWidget);
    expect(selectedMp3, findsOneWidget);
    expect(
      tester.getRect(audioFormatRow).right - tester.getRect(selectedMp3).right,
      lessThan(44),
    );

    await tester.tap(find.text('StepFun'));
    await tester.pumpAndSettle();
    expect(find.text('Output format'), findsOneWidget);
    expect(find.text('Style / voice description'), findsOneWidget);
    expect(find.text('flac'), findsNothing);

    await tester.tap(find.text('Fish Audio'));
    await tester.pumpAndSettle();
    expect(find.text('Temperature'), findsOneWidget);
    expect(find.text('Top P'), findsOneWidget);
    expect(find.text('Latency'), findsOneWidget);

    await tester.tap(find.text('ElevenLabs'));
    await tester.pumpAndSettle();
    expect(find.text('Output format'), findsOneWidget);

    await tester.tap(find.text('MiMo'));
    await tester.pumpAndSettle();
    expect(find.text('Style / voice description'), findsOneWidget);
    expect(find.text('Streaming'), findsOneWidget);

    final mobileModelField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.controller?.text == 'mimo-v2.5-tts',
    );
    expect(mobileModelField, findsOneWidget);
    await tester.enterText(mobileModelField, 'mimo-future-tts');
    await tester.pump();
    final customModelField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.controller?.text == 'mimo-future-tts',
    );
    final customModelTextField = tester.widget<TextField>(customModelField);
    expect(customModelTextField.controller?.text, 'mimo-future-tts');
    await tester.enterText(customModelField, 'mimo-v2.5-tts-voiceclone');
    await tester.pump();
    await tester.dragUntilVisible(
      find.text('Choose reference audio'),
      find.byType(ListView),
      const Offset(0, -180),
    );
    expect(find.text('Reference audio (WAV/MP3 data URI)'), findsOneWidget);
    expect(find.text('Choose reference audio'), findsOneWidget);
  });

  testWidgets('desktop TTS editor exposes provider advanced fields', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = SettingsProvider(createBusinessTestPreferences());
    final tts = TtsProvider(preferences: createBusinessTestPreferences());
    addTearDown(tts.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<TtsProvider>.value(value: tts),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: DesktopTtsServicesPane()),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Add TTS Service'), findsOneWidget);
    expect(find.byType(VoiceServiceSelectRow<String>), findsOneWidget);

    Future<void> selectProvider(String current, String next) async {
      await tester.tap(find.text(current).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(next).last);
      await tester.pumpAndSettle();
    }

    await selectProvider('OpenAI', 'Fish Audio');
    expect(find.text('Temperature'), findsOneWidget);
    expect(find.text('Top P'), findsOneWidget);
    expect(find.text('Latency'), findsOneWidget);

    await selectProvider('Fish Audio', 'MiniMax');
    expect(find.text('Auto match'), findsOneWidget);
    expect(find.text('Volume'), findsOneWidget);
    expect(find.text('Generate subtitles'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);

    await selectProvider('MiniMax', 'Qwen Audio');
    expect(find.text('Workspace ID'), findsOneWidget);
    expect(find.text('Region'), findsOneWidget);
    expect(find.text('Audio format'), findsOneWidget);

    await selectProvider('Qwen Audio', 'StepFun');
    expect(find.text('Output format'), findsOneWidget);
    expect(find.text('Style / voice description'), findsOneWidget);

    await selectProvider('StepFun', 'MiMo');
    expect(find.text('Style / voice description'), findsOneWidget);
    expect(find.text('Streaming'), findsOneWidget);

    final desktopModelField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.controller?.text == 'mimo-v2.5-tts',
    );
    expect(desktopModelField, findsOneWidget);
    await tester.enterText(desktopModelField, 'mimo-future-tts');
    await tester.pump();
    expect(find.text('mimo-future-tts'), findsOneWidget);

    await selectProvider('MiMo', 'ElevenLabs');
    expect(find.text('Output format'), findsOneWidget);

    await selectProvider('ElevenLabs', 'Azure');
    expect(find.text('Model'), findsNothing);
    expect(find.text('Language'), findsOneWidget);
  });
}
