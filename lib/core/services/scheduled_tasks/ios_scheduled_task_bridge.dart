import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'scheduled_task_execution_service.dart';

class IosScheduledTaskBridge {
  IosScheduledTaskBridge._();

  static final IosScheduledTaskBridge instance = IosScheduledTaskBridge._();
  static const MethodChannel _channel = MethodChannel('app.scheduled_tasks');

  bool _initialized = false;
  BuildContext? Function()? _contextProvider;

  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> initialize(BuildContext? Function() contextProvider) async {
    if (!isSupported) return;
    _contextProvider = contextProvider;
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleNativeCall);
    try {
      await _channel.invokeMethod<bool>('setReady');
      final pending = await _channel.invokeListMethod<String>(
        'consumePendingTriggers',
      );
      for (final triggerId in pending ?? const <String>[]) {
        if (triggerId.trim().isEmpty) continue;
        unawaited(_executeWhenContextReady(triggerId.trim()));
      }
    } catch (error) {
      debugPrint('[ScheduledTaskBridge] initialization failed: $error');
    }
  }

  Future<bool> openShortcutSetup({
    required String triggerId,
    required String taskName,
  }) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('openShortcutSetup', <String, Object?>{
            'triggerId': triggerId,
            'taskName': taskName,
          }) ??
          false;
    } catch (error) {
      debugPrint('[ScheduledTaskBridge] open Shortcuts failed: $error');
      return false;
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method != 'executeTrigger') return null;
    final args = call.arguments;
    final triggerId = args is Map ? args['triggerId']?.toString().trim() : null;
    if (triggerId == null || triggerId.isEmpty) {
      return const <String, dynamic>{'handled': false, 'success': false};
    }
    final result = await _executeWhenContextReady(triggerId);
    return result.toMap();
  }

  Future<ScheduledTaskExecutionResult> _executeWhenContextReady(
    String triggerId,
  ) async {
    // Flutter can receive an App Intent during cold startup before the first
    // MaterialApp frame exposes navigatorKey.currentContext. Give startup a
    // short bounded window; the native side also queues triggers until Dart
    // declares itself ready.
    for (var attempt = 0; attempt < 40; attempt++) {
      final context = _contextProvider?.call();
      if (context != null) {
        return ScheduledTaskExecutionService.executeTrigger(
          // ignore: use_build_context_synchronously (root context, valid for app lifetime)
          context: context,
          triggerId: triggerId,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return const ScheduledTaskExecutionResult(
      handled: false,
      error: 'flutter_context_unavailable',
    );
  }
}
