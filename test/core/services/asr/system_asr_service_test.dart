import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/asr/system_asr_service.dart';

void main() {
  test('macOS plugin is guarded in IDE builds and enabled in release', () {
    expect(
      canInitializeSystemAsrOnPlatform(
        TargetPlatform.macOS,
        isReleaseMode: false,
      ),
      isFalse,
    );
    expect(
      canInitializeSystemAsrOnPlatform(
        TargetPlatform.macOS,
        isReleaseMode: true,
      ),
      isTrue,
    );
    expect(canInitializeSystemAsrOnPlatform(TargetPlatform.iOS), isTrue);
    expect(canInitializeSystemAsrOnPlatform(TargetPlatform.android), isTrue);
  });

  test(
    'the real backend short-circuits before the macOS plugin channel',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final backend = SpeechToTextSystemAsrBackend();

      expect(
        await backend.initialize(onError: (_) {}, onStatus: (_) {}),
        isFalse,
      );
    },
  );

  test('macOS bundle declares speech-recognition privacy usage', () {
    final infoPlist = File('macos/Runner/Info.plist').readAsStringSync();

    expect(
      infoPlist,
      contains('<key>NSSpeechRecognitionUsageDescription</key>'),
    );
  });

  group('SystemAsrService', () {
    test(
      'initializes the backend only once, including concurrent callers',
      () async {
        final backend = _FakeSystemAsrBackend();
        final pendingInitialization = Completer<bool>();
        backend.initializeCompleter = pendingInitialization;
        final service = SystemAsrService(backend: backend);

        final first = service.initialize();
        final second = service.initialize();
        pendingInitialization.complete(true);

        expect(await first, isTrue);
        expect(await second, isTrue);
        expect(backend.initializeCalls, 1);
        expect(service.isAvailable, isTrue);
        expect(service.state, SystemAsrState.ready);
      },
    );

    test(
      'exposes locales and the system locale after initialization',
      () async {
        final backend = _FakeSystemAsrBackend()
          ..availableLocales = const <SystemAsrLocale>[
            SystemAsrLocale(id: 'en_US', name: 'English'),
            SystemAsrLocale(id: 'zh_CN', name: '中文'),
          ]
          ..currentSystemLocale = const SystemAsrLocale(
            id: 'zh_CN',
            name: '中文',
          );
        final service = SystemAsrService(backend: backend);

        expect(await service.locales, backend.availableLocales);
        expect(
          await service.systemLocale,
          const SystemAsrLocale(id: 'zh_CN', name: '中文'),
        );
        expect(backend.initializeCalls, 1);
        expect(backend.localesCalls, 1);
        expect(backend.systemLocaleCalls, 1);
      },
    );

    test('does not query or listen when recognition is unavailable', () async {
      final backend = _FakeSystemAsrBackend()..initializeResult = false;
      final service = SystemAsrService(backend: backend);

      expect(await service.locales, isEmpty);
      expect(await service.systemLocale, isNull);
      expect(
        await service.start(
          onTranscript: (_, _) {},
          onSoundLevel: (_) {},
          onError: (_) {},
        ),
        isFalse,
      );
      expect(service.state, SystemAsrState.unavailable);
      expect(backend.initializeCalls, 1);
      expect(backend.localesCalls, 0);
      expect(backend.systemLocaleCalls, 0);
      expect(backend.listenCalls, 0);
    });

    test(
      'releases the active-session guard when initialization throws',
      () async {
        final backend = _FakeSystemAsrBackend()
          ..initializeError = StateError('initialization failed');
        final service = SystemAsrService(backend: backend);

        await expectLater(
          service.start(
            onTranscript: (_, _) {},
            onSoundLevel: (_) {},
            onError: (_) {},
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'initialization failed',
            ),
          ),
        );
        await expectLater(
          service.start(
            onTranscript: (_, _) {},
            onSoundLevel: (_) {},
            onError: (_) {},
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'initialization failed',
            ),
          ),
        );
        expect(service.state, SystemAsrState.unavailable);
        expect(backend.initializeCalls, 1);
      },
    );

    test(
      'starts dictation with bounded durations and forwards callbacks',
      () async {
        final backend = _FakeSystemAsrBackend();
        final service = SystemAsrService(backend: backend);
        final transcripts = <(String, bool)>[];
        final levels = <double>[];
        final errors = <SystemAsrError>[];

        expect(
          await service.start(
            localeId: 'zh_CN',
            onTranscript: (text, isFinal) => transcripts.add((text, isFinal)),
            onSoundLevel: levels.add,
            onError: errors.add,
          ),
          isTrue,
        );
        backend.emitTranscript('你好', false);
        backend.emitTranscript('你好世界', true);
        backend.emitSoundLevel(3.5);
        backend.emitError(
          const SystemAsrError(message: 'temporary', isPermanent: false),
        );

        expect(service.state, SystemAsrState.listening);
        expect(backend.listenCalls, 1);
        expect(backend.lastLocaleId, 'zh_CN');
        expect(backend.lastListenFor, SystemAsrService.defaultListenFor);
        expect(backend.lastPauseFor, SystemAsrService.defaultPauseFor);
        expect(transcripts, <(String, bool)>[('你好', false), ('你好世界', true)]);
        expect(levels, <double>[3.5]);
        expect(errors.single.message, 'temporary');
      },
    );

    test(
      'rejects a second start while initialization is in progress',
      () async {
        final backend = _FakeSystemAsrBackend();
        final pendingInitialization = Completer<bool>();
        backend.initializeCompleter = pendingInitialization;
        final service = SystemAsrService(backend: backend);

        final firstStart = service.start(
          onTranscript: (_, _) {},
          onSoundLevel: (_) {},
          onError: (_) {},
        );
        await Future<void>.delayed(Duration.zero);

        await expectLater(
          service.start(
            onTranscript: (_, _) {},
            onSoundLevel: (_) {},
            onError: (_) {},
          ),
          throwsStateError,
        );

        pendingInitialization.complete(true);
        expect(await firstStart, isTrue);
        expect(backend.listenCalls, 1);
      },
    );

    test('cancel invalidates a start waiting for initialization', () async {
      final backend = _FakeSystemAsrBackend();
      final pendingInitialization = Completer<bool>();
      backend.initializeCompleter = pendingInitialization;
      final service = SystemAsrService(backend: backend);

      final pendingStart = service.start(
        onTranscript: (_, _) {},
        onSoundLevel: (_) {},
        onError: (_) {},
      );
      await Future<void>.delayed(Duration.zero);

      await service.cancel();
      pendingInitialization.complete(true);

      expect(await pendingStart, isFalse);
      expect(backend.cancelCalls, 1);
      expect(backend.listenCalls, 0);
      expect(service.state, SystemAsrState.ready);
    });

    test(
      'stop waits for done status before accepting another session',
      () async {
        final backend = _FakeSystemAsrBackend();
        final service = SystemAsrService(backend: backend);
        await service.start(
          onTranscript: (_, _) {},
          onSoundLevel: (_) {},
          onError: (_) {},
        );

        await service.stop();
        await service.stop();

        expect(backend.stopCalls, 1);
        expect(service.state, SystemAsrState.stopping);
        await expectLater(
          service.start(
            onTranscript: (_, _) {},
            onSoundLevel: (_) {},
            onError: (_) {},
          ),
          throwsStateError,
        );

        backend.emitStatus('done');
        expect(service.state, SystemAsrState.ready);
        expect(
          await service.start(
            onTranscript: (_, _) {},
            onSoundLevel: (_) {},
            onError: (_) {},
          ),
          isTrue,
        );
        expect(backend.listenCalls, 2);
      },
    );

    test('cancel is idempotent and suppresses later callbacks', () async {
      final backend = _FakeSystemAsrBackend();
      final service = SystemAsrService(backend: backend);
      final transcripts = <String>[];
      await service.start(
        onTranscript: (text, _) => transcripts.add(text),
        onSoundLevel: (_) {},
        onError: (_) {},
      );

      await service.cancel();
      await service.cancel();
      backend.emitTranscript('ignored', true);

      expect(backend.cancelCalls, 1);
      expect(service.state, SystemAsrState.ready);
      expect(transcripts, isEmpty);
    });

    test('a permanent error waits for the platform done status', () async {
      final backend = _FakeSystemAsrBackend();
      final service = SystemAsrService(backend: backend);
      final errors = <SystemAsrError>[];
      await service.start(
        onTranscript: (_, _) {},
        onSoundLevel: (_) {},
        onError: errors.add,
      );

      backend.emitError(
        const SystemAsrError(message: 'permission denied', isPermanent: true),
      );

      expect(errors.single.message, 'permission denied');
      expect(service.state, SystemAsrState.stopping);
      await expectLater(
        service.start(
          onTranscript: (_, _) {},
          onSoundLevel: (_) {},
          onError: (_) {},
        ),
        throwsStateError,
      );
      backend.emitStatus('done');
      expect(service.state, SystemAsrState.ready);
    });

    test(
      'dispose cancels an active session and prevents further use',
      () async {
        final backend = _FakeSystemAsrBackend();
        final service = SystemAsrService(backend: backend);
        await service.start(
          onTranscript: (_, _) {},
          onSoundLevel: (_) {},
          onError: (_) {},
        );

        await service.dispose();
        await service.dispose();

        expect(service.state, SystemAsrState.disposed);
        expect(backend.cancelCalls, 1);
        expect(service.initialize, throwsStateError);
        expect(() => service.locales, throwsStateError);
      },
    );
  });
}

class _FakeSystemAsrBackend implements SystemAsrBackend {
  bool initializeResult = true;
  Object? initializeError;
  Completer<bool>? initializeCompleter;
  List<SystemAsrLocale> availableLocales = const <SystemAsrLocale>[];
  SystemAsrLocale? currentSystemLocale;

  int initializeCalls = 0;
  int localesCalls = 0;
  int systemLocaleCalls = 0;
  int listenCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  String? lastLocaleId;
  Duration? lastListenFor;
  Duration? lastPauseFor;

  SystemAsrErrorCallback? _onError;
  void Function(String status)? _onStatus;
  SystemAsrTranscriptCallback? _onTranscript;
  SystemAsrSoundLevelCallback? _onSoundLevel;

  @override
  Future<bool> initialize({
    required SystemAsrErrorCallback onError,
    required void Function(String status) onStatus,
  }) async {
    initializeCalls += 1;
    _onError = onError;
    _onStatus = onStatus;
    if (initializeError case final error?) throw error;
    return initializeCompleter?.future ?? initializeResult;
  }

  @override
  Future<List<SystemAsrLocale>> locales() async {
    localesCalls += 1;
    return availableLocales;
  }

  @override
  Future<SystemAsrLocale?> systemLocale() async {
    systemLocaleCalls += 1;
    return currentSystemLocale;
  }

  @override
  Future<void> listen({
    required String? localeId,
    required Duration listenFor,
    required Duration pauseFor,
    required SystemAsrTranscriptCallback onTranscript,
    required SystemAsrSoundLevelCallback onSoundLevel,
  }) async {
    listenCalls += 1;
    lastLocaleId = localeId;
    lastListenFor = listenFor;
    lastPauseFor = pauseFor;
    _onTranscript = onTranscript;
    _onSoundLevel = onSoundLevel;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }

  @override
  Future<void> cancel() async {
    cancelCalls += 1;
  }

  void emitTranscript(String text, bool isFinal) {
    _onTranscript?.call(text, isFinal);
  }

  void emitSoundLevel(double level) {
    _onSoundLevel?.call(level);
  }

  void emitError(SystemAsrError error) {
    _onError?.call(error);
  }

  void emitStatus(String status) {
    _onStatus?.call(status);
  }
}
