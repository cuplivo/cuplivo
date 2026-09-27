import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';

import '../models/assistant.dart';
import '../models/conversation.dart';
import 'notification_service.dart';
import 'proactive_care_conversation_policy.dart';

/// Dart side of the native proactive-care alarm registry.
///
/// Native owner: `android/.../scheduled/ProactiveCareAlarms.kt` over
/// MethodChannel `app.proactive_care_alarms`. The native side stores
/// one-shot exact alarms keyed by conversation id and wakes the Flutter
/// engine (foreground service) when one fires while the process is dead;
/// a live engine receives the `fire` call directly. Delivery itself always
/// runs on the provider stack in the main isolate — the alarm only triggers
/// it, mirroring the scheduled-tasks architecture.
class ProactiveCareAlarmService {
  ProactiveCareAlarmService._();

  static const MethodChannel _channel = MethodChannel(
    'app.proactive_care_alarms',
  );

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// Stable conversation-owned id shared by the alarm and the letter
  /// notification (FNV-1a over the id, 31-bit space).
  static int alarmIdFor(String conversationId) =>
      NotificationService.proactiveCareIdFor(conversationId);

  /// Eligible schedules that still lie in the future, for re-arming after a
  /// reboot, a time change or an alarm-permission grant.
  @visibleForTesting
  static List<ProactiveCareConversationTarget> pendingForReschedule({
    required List<Conversation> conversations,
    required List<Assistant> assistants,
    DateTime? now,
  }) => ProactiveCareConversationPolicy.pending(
    conversations: conversations,
    assistants: assistants,
    now: now,
  );

  /// Installs the fire handler and marks the Dart side ready. Every fire is
  /// forwarded to [onFire]; once it settles (success or failure) the native
  /// scheduled run is completed so the foreground service can stop.
  static Future<void> attach(
    Future<void> Function(String conversationId, DateTime expectedAt) onFire,
  ) async {
    if (!isSupported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'fire') return null;
      final args = Map<Object?, Object?>.from(call.arguments as Map);
      final conversationId = args['conversationId'];
      final dueAtMillis = args['dueAt'];
      if (conversationId is! String || dueAtMillis is! int) {
        debugPrint('[ProactiveCareAlarm] invalid fire payload: $args');
        return null;
      }
      final expectedAt = DateTime.fromMillisecondsSinceEpoch(dueAtMillis);
      try {
        await onFire(conversationId, expectedAt);
      } catch (e, st) {
        debugPrint('[ProactiveCareAlarm] fire handling failed: $e\n$st');
      } finally {
        await _completeRun(conversationId);
      }
      return null;
    });
    try {
      await _channel.invokeMethod<void>('ready');
    } catch (e) {
      debugPrint('[ProactiveCareAlarm] ready failed: $e');
    }
  }

  static Future<void> detach() async {
    if (!isSupported) return;
    try {
      _channel.setMethodCallHandler(null);
    } catch (_) {}
  }

  static Future<void> _completeRun(String conversationId) async {
    try {
      await _channel.invokeMethod<void>('done', {
        'conversationId': conversationId,
      });
    } catch (e) {
      debugPrint('[ProactiveCareAlarm] done failed: $e');
    }
  }

  /// Arms or cancels the conversation's one-shot alarm according to its
  /// persisted schedule and eligibility. Past times are cancelled (the
  /// start/resume catch-up delivers them instead). A null [assistant]
  /// (deleted owner, resolver unwired) counts as ineligible.
  static Future<void> sync({
    required Conversation conversation,
    required Assistant? assistant,
  }) async {
    if (!isSupported) return;
    try {
      final at =
          assistant != null &&
              ProactiveCareConversationPolicy.isEligible(
                conversation,
                assistant,
              )
          ? conversation.proactiveCareNextMessageAt
          : null;
      if (at == null || !at.isAfter(DateTime.now())) {
        await cancelFor(conversation.id);
        return;
      }
      await _channel.invokeMethod<void>('sync', {
        'conversationId': conversation.id,
        'dueAt': at.millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('[ProactiveCareAlarm] sync failed: $e');
    }
  }

  static Future<void> cancelFor(String conversationId) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('cancel', {
        'conversationId': conversationId,
      });
    } catch (e) {
      debugPrint('[ProactiveCareAlarm] cancel failed: $e');
    }
  }

  /// Re-arms every pending future schedule (app start, alarm permission
  /// granted, restore import).
  static Future<void> rescheduleAll({
    required List<Conversation> conversations,
    required List<Assistant> assistants,
  }) async {
    if (!isSupported) return;
    try {
      final pending = pendingForReschedule(
        conversations: conversations,
        assistants: assistants,
      );
      final payload = [
        for (final target in pending)
          {
            'conversationId': target.conversation.id,
            'dueAt': target.expectedAt.millisecondsSinceEpoch,
          },
      ];
      await _channel.invokeMethod<void>('rescheduleAll', {'alarms': payload});
    } catch (e) {
      debugPrint('[ProactiveCareAlarm] rescheduleAll failed: $e');
    }
  }
}
