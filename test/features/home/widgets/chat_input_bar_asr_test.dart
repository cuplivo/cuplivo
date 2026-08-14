import '../../../support/business_test_harness.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/core/providers/asr_provider.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/input_status_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/asr/asr_audio_capture.dart';
import 'package:Cuplivo/core/services/asr/asr_service_options.dart';
import 'package:Cuplivo/core/services/asr/system_asr_service.dart';
import 'package:Cuplivo/features/home/services/input_draft_persistence.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_bar.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

void main() {
  Widget harness({
    required SettingsProvider settings,
    required AsrProvider asr,
    required TextEditingController controller,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: AssistantProvider()),
        ChangeNotifierProvider.value(value: InputStatusProvider()),
        Provider<InputDraftPersistence>(
          create: (_) => InputDraftPersistence(null),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ChatInputBar(
            controller: controller,
            asrProvider: asr,
            onSend: (_) async => ChatInputSubmissionResult.rejected,
          ),
        ),
      ),
    );
  }

  testWidgets('microphone is hidden until the user adds an ASR service', (
    tester,
  ) async {
    final settings = await createBusinessTestPreferences();
    final asr = AsrProvider();
    final controller = TextEditingController();
    addTearDown(asr.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      harness(settings: settings, asr: asr, controller: controller),
    );
    await tester.pump();

    expect(find.byTooltip('Voice input'), findsNothing);
  });

  testWidgets('system ASR replaces partials from a stable draft base', (
    tester,
  ) async {
    final settings = await createBusinessTestPreferences();
    final option = SystemAsrOptions(id: 'system-test');
    await settings.setAsrServices(<AsrServiceOptions>[option]);
    final backend = _FakeSystemBackend();
    final asr = AsrProvider(systemService: SystemAsrService(backend: backend));
    final controller = TextEditingController(text: 'draft');
    addTearDown(asr.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      harness(settings: settings, asr: asr, controller: controller),
    );
    await tester.tap(find.byTooltip('Voice input'));
    await tester.pump();

    backend.emitTranscript('hello', false);
    await tester.pump();
    expect(controller.text, 'draft hello');
    backend.emitTranscript('hello world', false);
    await tester.pump();
    expect(controller.text, 'draft hello world');

    await tester.tap(find.byTooltip('Stop and transcribe to input'));
    await tester.pumpAndSettle();
    expect(controller.text, 'draft hello world');
    expect(find.byTooltip('Voice input'), findsOneWidget);
  });

  testWidgets('cancelling ASR restores the exact original editing value', (
    tester,
  ) async {
    final settings = await createBusinessTestPreferences();
    final option = SystemAsrOptions(id: 'system-test');
    await settings.setAsrServices(<AsrServiceOptions>[option]);
    final backend = _FakeSystemBackend();
    final asr = AsrProvider(systemService: SystemAsrService(backend: backend));
    final controller = TextEditingController(text: '保留内容')
      ..selection = const TextSelection(baseOffset: 1, extentOffset: 3);
    final original = controller.value;
    addTearDown(asr.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      harness(settings: settings, asr: asr, controller: controller),
    );
    await tester.tap(find.byTooltip('Voice input'));
    await tester.pump();
    backend.emitTranscript('临时识别', false);
    await tester.pump();

    await tester.tap(find.byTooltip('Discard recording'));
    await tester.pumpAndSettle();
    expect(controller.value, original);
  });

  testWidgets('voice waveform advances on a steady 60 ms sampling clock', (
    tester,
  ) async {
    final settings = await createBusinessTestPreferences();
    final option = SystemAsrOptions(id: 'system-test');
    await settings.setAsrServices(<AsrServiceOptions>[option]);
    final backend = _FakeSystemBackend();
    final asr = AsrProvider(systemService: SystemAsrService(backend: backend));
    final controller = TextEditingController();
    addTearDown(asr.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      harness(settings: settings, asr: asr, controller: controller),
    );
    await tester.tap(find.byTooltip('Voice input'));
    await tester.pump();
    backend.emitSoundLevel(-12);
    await tester.pump();

    dynamic waveform = tester.widget(
      find.byKey(const ValueKey('voice-waveform')),
    );
    expect(waveform.levels, isEmpty);
    await tester.pump(const Duration(milliseconds: 65));
    waveform = tester.widget(find.byKey(const ValueKey('voice-waveform')));
    final firstCount = (waveform.levels as List<double>).length;
    expect(firstCount, greaterThan(0));
    final waveformPaint = find.descendant(
      of: find.byKey(const ValueKey('voice-waveform')),
      matching: find.byType(CustomPaint),
    );
    expect(waveformPaint, findsOneWidget);
    expect(tester.getSize(waveformPaint).width, greaterThan(0));
    expect(tester.getSize(waveformPaint).height, 32);

    await tester.pump(const Duration(milliseconds: 180));
    waveform = tester.widget(find.byKey(const ValueKey('voice-waveform')));
    expect((waveform.levels as List<double>).length, greaterThan(firstCount));

    await tester.tap(find.byTooltip('Discard recording'));
    await tester.pumpAndSettle();
  });

  testWidgets('local transcription shows a custom recognizing indicator', (
    tester,
  ) async {
    final settings = await createBusinessTestPreferences();
    final option = SherpaOnnxAsrOptions(
      id: 'local-test',
      modelId: 'local-model',
    );
    await settings.setAsrServices(<AsrServiceOptions>[option]);
    final capture = _FakeAudioCapture();
    final transcription = Completer<String>();
    var transcriptionCalls = 0;
    final asr = AsrProvider(
      audioCaptureFactory: () => capture,
      localModelInstalledChecker: (_) async => true,
      localTranscriber: (_, _) {
        transcriptionCalls++;
        return transcription.future;
      },
    );
    await asr.refreshAvailability(option);
    final controller = TextEditingController();
    addTearDown(asr.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      harness(settings: settings, asr: asr, controller: controller),
    );
    await tester.tap(find.byTooltip('Voice input'));
    await tester.pump();
    capture.add(_pcm16(6000));
    await tester.pump(const Duration(milliseconds: 65));

    expect(asr.soundLevel, greaterThan(0));
    final dynamic localWaveform = tester.widget(
      find.byKey(const ValueKey('voice-waveform')),
    );
    expect((localWaveform.levels as List<double>).last, greaterThan(0));
    final localWaveformPaint = find.descendant(
      of: find.byKey(const ValueKey('voice-waveform')),
      matching: find.byType(CustomPaint),
    );
    expect(tester.getSize(localWaveformPaint).width, greaterThan(0));
    expect(tester.getSize(localWaveformPaint).height, 32);

    await tester.tap(find.byTooltip('Stop and transcribe to input'));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('voice-transcribing-indicator')),
      findsOneWidget,
    );
    expect(find.text('Recognizing…'), findsOneWidget);
    expect(transcriptionCalls, 1);

    await tester.tap(find.byTooltip('Stop and transcribe to input'));
    await tester.pump();
    expect(transcriptionCalls, 1);

    transcription.complete('local result');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    for (var attempt = 0; attempt < 10 && controller.text.isEmpty; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 200));

    expect(controller.text, 'local result');
    expect(
      find.byKey(const ValueKey('voice-transcribing-indicator')),
      findsNothing,
    );
  });
}

final class _FakeSystemBackend implements SystemAsrBackend {
  void Function(String status)? _onStatus;
  SystemAsrTranscriptCallback? _onTranscript;
  SystemAsrSoundLevelCallback? _onSoundLevel;

  void emitTranscript(String text, bool isFinal) {
    _onTranscript?.call(text, isFinal);
  }

  void emitSoundLevel(double level) {
    _onSoundLevel?.call(level);
  }

  @override
  Future<bool> initialize({
    required SystemAsrErrorCallback onError,
    required void Function(String status) onStatus,
  }) async {
    _onStatus = onStatus;
    return true;
  }

  @override
  Future<List<SystemAsrLocale>> locales() async => const <SystemAsrLocale>[];

  @override
  Future<SystemAsrLocale?> systemLocale() async => null;

  @override
  Future<void> listen({
    required String? localeId,
    required Duration listenFor,
    required Duration pauseFor,
    required SystemAsrTranscriptCallback onTranscript,
    required SystemAsrSoundLevelCallback onSoundLevel,
  }) async {
    _onTranscript = onTranscript;
    _onSoundLevel = onSoundLevel;
    _onStatus?.call('listening');
  }

  @override
  Future<void> stop() async {
    _onTranscript?.call('hello world', true);
    _onStatus?.call('done');
  }

  @override
  Future<void> cancel() async {
    _onStatus?.call('done');
  }
}

final class _FakeAudioCapture implements AsrAudioCapture {
  final StreamController<Uint8List> _controller =
      StreamController<Uint8List>.broadcast();

  void add(Uint8List chunk) => _controller.add(chunk);

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<Uint8List>> start({required int sampleRate}) async =>
      _controller.stream;

  @override
  Future<void> stop() async {
    if (!_controller.isClosed) await _controller.close();
  }

  @override
  Future<void> cancel() async {
    if (!_controller.isClosed) await _controller.close();
  }

  @override
  Future<void> dispose() async {
    if (!_controller.isClosed) await _controller.close();
  }
}

Uint8List _pcm16(int value) {
  final result = Uint8List(64);
  final data = ByteData.sublistView(result);
  for (var offset = 0; offset < result.length; offset += 2) {
    data.setInt16(offset, value, Endian.little);
  }
  return result;
}
