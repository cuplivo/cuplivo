import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';

import '../models/assistant.dart';
import '../models/conversation.dart';
import 'desktop_proactive_care_scheduler.dart';
import 'ios_proactive_care_scheduler.dart';
import 'notification_service.dart';
import 'proactive_care_conversation_policy.dart';

/// Cross-platform proactive-care alarm & scheduling service facade.
///
/// Native Android owner: `android/.../scheduled/ProactiveCareAlarms.kt` over
/// MethodChannel `app.proactive_care_alarms`.
/// Desktop owner: `DesktopProactiveCareScheduler` with system power sleep/wake tracking.
/// iOS owner: `IosProactiveCareScheduler` with `app.scheduled_notifications`.
class ProactiveCareAlarmService {
  ProactiveCareAlarmService._();

  static const MethodChannel _channel = MethodChannel(
    'app.proactive_care_alarms',
  );

  static bool get isSupported => !kIsWeb;

  /// Localized line for the iOS arrival notification, wired at startup. iOS
  /// cannot generate the letter on a timer, so the notification announces it
  /// and the letter is delivered by the start/resume catch-up.
  static String? Function()? proactiveCareArrivalBodyResolver;

  static DesktopProactiveCareScheduler? _desktopScheduler;
  static IosProactiveCareScheduler? _iosScheduler;

  static IosProactiveCareScheduler _ensureIosScheduler() =>
      _iosScheduler ??= IosProactiveCareScheduler(
        arrivalBodyResolver: () => proactiveCareArrivalBodyResolver?.call(),
      );

  @visibleForTesting
  static DesktopProactiveCareScheduler? get desktopScheduler =>
      _desktopScheduler;

  @visibleForTesting
  static void setDesktopSchedulerForTesting(
    DesktopProactiveCareScheduler? scheduler,
  ) {
    _desktopScheduler = scheduler;
  }

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

    if (!kIsWeb &&
        (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      _desktopScheduler ??= DesktopProactiveCareScheduler();
      await _desktopScheduler!.attach(onFire);
      return;
    }

    if (!kIsWeb && Platform.isIOS) {
      await _ensureIosScheduler().attach(onFire);
      return;
    }

    if (!kIsWeb && Platform.isAndroid) {
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
  }

  static Future<void> detach() async {
    if (!isSupported) return;
    if (_desktopScheduler != null) {
      await _desktopScheduler!.detach();
    }
    if (_iosScheduler != null) {
      await _iosScheduler!.detach();
    }
    if (!kIsWeb && Platform.isAndroid) {
      try {
        _channel.setMethodCallHandler(null);
      } catch (_) {}
    }
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

    if (!kIsWeb &&
        (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      _desktopScheduler ??= DesktopProactiveCareScheduler();
      await _desktopScheduler!.sync(
        conversation: conversation,
        assistant: assistant,
      );
      return;
    }

    if (!kIsWeb && Platform.isIOS) {
      await _ensureIosScheduler().sync(
        conversation: conversation,
        assistant: assistant,
      );
      return;
    }

    if (!kIsWeb && Platform.isAndroid) {
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
  }

  static Future<void> cancelFor(String conversationId) async {
    if (!isSupported) return;

    if (!kIsWeb &&
        (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      await _desktopScheduler?.cancelFor(conversationId);
      return;
    }

    if (!kIsWeb && Platform.isIOS) {
      await _iosScheduler?.cancelFor(conversationId);
      return;
    }

    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod<void>('cancel', {
          'conversationId': conversationId,
        });
      } catch (e) {
        debugPrint('[ProactiveCareAlarm] cancel failed: $e');
      }
    }
  }

  /// Re-arms every pending future schedule (app start, alarm permission
  /// granted, restore import).
  static Future<void> rescheduleAll({
    required List<Conversation> conversations,
    required List<Assistant> assistants,
  }) async {
    if (!isSupported) return;

    if (!kIsWeb &&
        (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      _desktopScheduler ??= DesktopProactiveCareScheduler();
      await _desktopScheduler!.rescheduleAll(
        conversations: conversations,
        assistants: assistants,
      );
      return;
    }

    if (!kIsWeb && Platform.isIOS) {
      await _ensureIosScheduler().rescheduleAll(
        conversations: conversations,
        assistants: assistants,
      );
      return;
    }

    if (!kIsWeb && Platform.isAndroid) {
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
}
