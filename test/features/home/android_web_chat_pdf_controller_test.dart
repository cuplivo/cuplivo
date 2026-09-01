import 'dart:async';
import 'dart:convert';
import 'package:Cuplivo/features/home/webview/android_web_chat_pdf_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(androidWebChatPdfChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('runs ready to envelope to print to dispose in order', () async {
    final calls = <MethodCall>[];
    final messages = <String>[];
    AndroidWebChatPdfController? controller;
    addTearDown(() async => controller?.dispose());
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'print') return 'completed';
      return null;
    });
    controller = AndroidWebChatPdfController(
      onMessage: (message) async => messages.add(message),
      onResourceError: (_) {},
      onDiagnostic: (_) {},
    );

    await controller.start();
    await _sendNativeMethod('bridgeMessage', '{"type":"ready"}');
    await controller.postEnvelope(<String, dynamic>{'type': 'transferChunk'});
    final status = await controller.print(documentName: 'Conversation');
    await controller.dispose();

    expect(messages, <String>['{"type":"ready"}']);
    expect(status, AndroidPdfPrintStatus.completed);
    expect(calls.map((call) => call.method), <String>[
      'start',
      'postEnvelope',
      'print',
      'dispose',
    ]);
    expect(jsonDecode(calls[1].arguments! as String), <String, dynamic>{
      'type': 'transferChunk',
    });
  });

  test(
    'rejects concurrency before replacing the active channel handler',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      final first = AndroidWebChatPdfController(
        onMessage: (_) async {},
        onResourceError: (_) {},
        onDiagnostic: (_) {},
      );
      final second = AndroidWebChatPdfController(
        onMessage: (_) async {},
        onResourceError: (_) {},
        onDiagnostic: (_) {},
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      await first.start();
      await expectLater(
        second.start(),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'busy',
          ),
        ),
      );
      await first.dispose();
      await second.start();
    },
  );

  test('propagates native print failure and cleans up only once', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'print') {
        throw PlatformException(
          code: 'print_failed',
          message: 'spooler failed',
        );
      }
      return null;
    });
    final controller = AndroidWebChatPdfController(
      onMessage: (_) async {},
      onResourceError: (_) {},
      onDiagnostic: (_) {},
    );
    addTearDown(controller.dispose);

    await controller.start();
    await expectLater(
      controller.print(documentName: 'Conversation'),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'print_failed',
        ),
      ),
    );
    await controller.dispose();
    await controller.dispose();

    expect(calls.where((method) => method == 'dispose'), hasLength(1));
  });

  test('routes resource and diagnostic callbacks from native', () async {
    int? resourceError;
    String? diagnostic;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    final controller = AndroidWebChatPdfController(
      onMessage: (_) async {},
      onResourceError: (value) => resourceError = value,
      onDiagnostic: (value) => diagnostic = value,
    );
    addTearDown(controller.dispose);

    await controller.start();
    await _sendNativeMethod('resourceError', -2);
    await _sendNativeMethod('diagnostic', 'render_process_gone');

    expect(resourceError, -2);
    expect(diagnostic, 'render_process_gone');
  });
}

Future<void> _sendNativeMethod(String method, Object? arguments) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final response = Completer<ByteData?>();
  await messenger.handlePlatformMessage(
    androidWebChatPdfChannelName,
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
    response.complete,
  );
  await response.future;
}
