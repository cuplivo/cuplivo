import 'dart:async';

import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        debugPrint,
        defaultTargetPlatform,
        kIsWeb,
        visibleForTesting;
import 'package:flutter/services.dart';

import '../../utils/platform_utils.dart';
import '../models/assistant.dart';
import '../models/conversation.dart';
import 'in_process_proactive_care_scheduler.dart';
import 'ios_proactive_care_scheduler.dart';
import 'notification_service.dart';
import 'proactive_care_conversation_policy.dart';

/// Cross-platform proactive-care alarm & scheduling service facade.
///
/// Care is a consumer of Kelivo's scheduled-task layer: every platform's
/// trigger is the one upstream already owns for that platform.
/// Native Android owner: `android/.../scheduled/ProactiveCareAlarms.kt` over
/// MethodChannel `app.proactive_care_alarms` (Kelivo has no in-app executor on
/// Android, so neither has care).
/// Desktop owner: [InProcessProactiveCareScheduler] with system power
/// sleep/wake tracking (the platform where care is the primary trigger).
/// iOS owner: [InProcessProactiveCareScheduler] while the app is alive (the
/// same in-app executor role Kelivo's own iOS scheduler runs due tasks with),
/// backed by `IosProactiveCareScheduler`'s arrival notification for a
/// suspended or dead app.
class ProactiveCareAlarmService {
  ProactiveCareAlarmService._();

  static const MethodChannel _channel = MethodChannel(
    'app.proactive_care_alarms',
  );

  static bool get isSupported => !kIsWeb;

  /// Platform checks read `defaultTargetPlatform` (the tree's shared pattern)
  /// so the Android branch stays unit-testable off-device.
  static bool get _isDesktopTarget => !kIsWeb && PlatformUtils.isDesktopTarget;
  static bool get _isAndroidTarget =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool get _isIOSTarget =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Localized line for the iOS arrival notification, wired at startup. iOS
  /// cannot generate the letter while the app is suspended, so the
  /// notification announces it and the letter is delivered by the in-app
  /// executor or the start/resume catch-up.
  static String? Function()? proactiveCareArrivalBodyResolver;

  static InProcessProactiveCareScheduler? _desktopScheduler;

  /// The platforms whose upstream counterpart is an in-app executor: desktop
  /// (primary owner) and iOS (foreground executor). Android deliberately has
  /// none — Kelivo's own Android scheduled tasks run through the native exact
  /// alarm only, so care consumes that and nothing else.
  static InProcessProactiveCareScheduler? _inProcessScheduler;
  static IosProactiveCareScheduler? _iosScheduler;

  static IosProactiveCareScheduler _ensureIosScheduler() =>
      _iosScheduler ??= IosProactiveCareScheduler(
        arrivalBodyResolver: () => proactiveCareArrivalBodyResolver?.call(),
      );

  @visibleForTesting
  static IosProactiveCareScheduler? get iosScheduler => _iosScheduler;

  @visibleForTesting
  static void setIosSchedulerForTesting(IosProactiveCareScheduler? scheduler) {
    _iosScheduler = scheduler;
  }

  /// The in-app trigger: primary owner on desktop, foreground executor on iOS.
  /// Created lazily so nothing polls before the app wired its fire handler.
  static InProcessProactiveCareScheduler _ensureInProcessScheduler() =>
      _inProcessScheduler ??= InProcessProactiveCareScheduler();

  @visibleForTesting
  static InProcessProactiveCareScheduler? get desktopScheduler =>
      _desktopScheduler;

  @visibleForTesting
  static void setDesktopSchedulerForTesting(
    InProcessProactiveCareScheduler? scheduler,
  ) {
    _desktopScheduler = scheduler;
  }

  /// Foreground executor for iOS: while the process is alive it delivers a due
  /// letter even when the arrival notification was suppressed because the app
  /// was already in the foreground. Created on [attach] only, so nothing starts
  /// polling before the app wired its fire handler. Null on every other
  /// platform, Android included.
  @visibleForTesting
  static InProcessProactiveCareScheduler? get inProcessScheduler =>
      _inProcessScheduler;

  @visibleForTesting
  static void setInProcessSchedulerForTesting(
    InProcessProactiveCareScheduler? scheduler,
  ) {
    _inProcessScheduler = scheduler;
  }

  /// Android only: whether the system lets this app schedule exact alarms, as
  /// reported by the native owner (the same fact Kelivo's scheduled-task
  /// surface reports). Null until the native side has answered.
  ///
  /// Diagnostic mirror only — the readiness UI reads
  /// `AndroidProactiveCareSettingsService`, which queries the grant itself.
  static bool? exactAlarmsPermitted;

  @visibleForTesting
  static void resetExactAlarmStatusForTesting() => exactAlarmsPermitted = null;

  static void _absorbExactAlarmStatus(Object? reply) {
    if (reply is Map && reply['exactAlarms'] is bool) {
      exactAlarmsPermitted = reply['exactAlarms'] as bool;
    }
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

    if (_isDesktopTarget) {
      _desktopScheduler ??= InProcessProactiveCareScheduler();
      await _desktopScheduler!.attach(onFire);
      return;
    }

    if (_isIOSTarget) {
      // Same foreground-executor contract as Android, and the same in-app
      // executor Kelivo's own iOS scheduler runs due work with: while the app
      // is alive the letter is generated here; the arrival notification stays
      // the fallback for a suspended or dead app.
      await _ensureInProcessScheduler().attach(onFire);
      await _ensureIosScheduler().attach(onFire);
      return;
    }

    if (_isAndroidTarget) {
      // Android consumes the native exact alarm only: Kelivo's own Android
      // scheduled tasks have no in-app executor either, so care must not add a
      // second trigger (and a permanent 1 s poll) of its own.
      _channel.setMethodCallHandler((call) async {
        if (call.method != 'fire') return null;
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        final conversationId = args['conversationId'];
        final dueAtMillis = args['dueAt'];
        if (conversationId is! String || dueAtMillis is! int) {
          debugPrint('[ProactiveCare] invalid fire payload: $args');
          return null;
        }
        final expectedAt = DateTime.fromMillisecondsSinceEpoch(dueAtMillis);
        debugPrint(
          '[ProactiveCare] native fire: $conversationId @ $expectedAt',
        );
        try {
          await onFire(conversationId, expectedAt);
        } catch (e, st) {
          debugPrint('[ProactiveCare] fire handling failed: $e\n$st');
        } finally {
          await _completeRun(conversationId);
        }
        return null;
      });
      try {
        await _channel.invokeMethod<void>('ready');
      } catch (e) {
        debugPrint('[ProactiveCare] ready failed: $e');
      }
    }
  }

  static Future<void> detach() async {
    if (!isSupported) return;
    if (_desktopScheduler != null) {
      await _desktopScheduler!.detach();
    }
    if (_inProcessScheduler != null) {
      await _inProcessScheduler!.detach();
    }
    if (_iosScheduler != null) {
      await _iosScheduler!.detach();
    }
    if (_isAndroidTarget) {
      try {
        _channel.setMethodCallHandler(null);
      } catch (_) {}
    }
    exactAlarmsPermitted = null;
  }

  static Future<void> _completeRun(String conversationId) async {
    try {
      await _channel.invokeMethod<void>('done', {
        'conversationId': conversationId,
      });
    } catch (e) {
      debugPrint('[ProactiveCare] done failed: $e');
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

    if (_isDesktopTarget) {
      _desktopScheduler ??= InProcessProactiveCareScheduler();
      await _desktopScheduler!.sync(
        conversation: conversation,
        assistant: assistant,
      );
      return;
    }

    if (_isIOSTarget) {
      // The in-app executor only exists once the app attached its fire
      // handler; mirroring into a null scheduler is a no-op.
      await _inProcessScheduler?.sync(
        conversation: conversation,
        assistant: assistant,
      );
      await _ensureIosScheduler().sync(
        conversation: conversation,
        assistant: assistant,
      );
      return;
    }

    if (_isAndroidTarget) {
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
          debugPrint('[ProactiveCare] alarm cancel: ${conversation.id}');
          await cancelFor(conversation.id);
          return;
        }
        debugPrint('[ProactiveCare] alarm arm: ${conversation.id} @ $at');
        final reply = await _channel.invokeMethod<Object?>('sync', {
          'conversationId': conversation.id,
          'dueAt': at.millisecondsSinceEpoch,
        });
        _absorbExactAlarmStatus(reply);
        if (exactAlarmsPermitted == false) {
          debugPrint(
            '[ProactiveCare] exact alarm not permitted; '
            '${conversation.id} only fires while the app is alive',
          );
        }
      } catch (e) {
        debugPrint('[ProactiveCare] alarm sync failed: $e');
      }
    }
  }

  static Future<void> cancelFor(String conversationId) async {
    if (!isSupported) return;

    if (_isDesktopTarget) {
      await _desktopScheduler?.cancelFor(conversationId);
      return;
    }

    if (_isIOSTarget) {
      await _inProcessScheduler?.cancelFor(conversationId);
      await _iosScheduler?.cancelFor(conversationId);
      return;
    }

    if (_isAndroidTarget) {
      try {
        await _channel.invokeMethod<void>('cancel', {
          'conversationId': conversationId,
        });
      } catch (e) {
        debugPrint('[ProactiveCare] alarm cancel failed: $e');
      }
    }
  }

  /// Whether [assistants] can resolve the owner of every conversation the
  /// re-arm would actually arm — a future schedule that [pendingForReschedule]
  /// would include once its owner is known. An unloaded assistant store, or a
  /// resolver that dropped an owner, makes the snapshot unusable for a
  /// replace-all: the conversation would silently fall out of the payload and
  /// lose its alarm.
  ///
  /// Schedules the re-arm omits by design must not veto it: a past-due one is
  /// cancelled on purpose, and one whose owner id is gone can never be armed
  /// again, so neither may block every other pending letter.
  static bool _resolvesEveryScheduledOwner(
    List<Conversation> conversations,
    List<Assistant> assistants, {
    DateTime? now,
  }) {
    final ownerIds = {for (final assistant in assistants) assistant.id};
    final current = now ?? DateTime.now();
    return !conversations.any(
      (conversation) =>
          conversation.assistantId != null &&
          conversation.proactiveCareNextMessageAt?.isAfter(current) == true &&
          !ownerIds.contains(conversation.assistantId),
    );
  }

  /// Re-arms every pending future schedule (app start, app resume, alarm
  /// permission granted, restore import). This only *consumes* the upstream
  /// re-arm API — it never owns timing itself on Android.
  ///
  /// Every owner is a replace-all: the native registry cancels whatever the
  /// payload omits and the in-process mirror clears and refills. A partial
  /// snapshot would therefore cancel letters it simply cannot see, so the call
  /// is refused outright when an owner is missing for a schedule that would
  /// otherwise be armed, rather than arming less than the caller asked for.
  static Future<void> rescheduleAll({
    required List<Conversation> conversations,
    required List<Assistant> assistants,
  }) async {
    if (!isSupported) return;

    final now = DateTime.now();
    if (!_resolvesEveryScheduledOwner(conversations, assistants, now: now)) {
      debugPrint(
        '[ProactiveCare] re-arm skipped: incomplete snapshot '
        '(${conversations.length} conversation(s), '
        '${assistants.length} owner(s))',
      );
      return;
    }

    if (_isDesktopTarget) {
      _desktopScheduler ??= InProcessProactiveCareScheduler();
      await _desktopScheduler!.rescheduleAll(
        conversations: conversations,
        assistants: assistants,
      );
      return;
    }

    if (_isIOSTarget) {
      await _inProcessScheduler?.rescheduleAll(
        conversations: conversations,
        assistants: assistants,
      );
      await _ensureIosScheduler().rescheduleAll(
        conversations: conversations,
        assistants: assistants,
      );
      return;
    }

    if (_isAndroidTarget) {
      try {
        final pending = pendingForReschedule(
          conversations: conversations,
          assistants: assistants,
          now: now,
        );
        debugPrint(
          '[ProactiveCare] re-arm ${pending.length} pending letter(s)',
        );
        final payload = [
          for (final target in pending)
            {
              'conversationId': target.conversation.id,
              'dueAt': target.expectedAt.millisecondsSinceEpoch,
            },
        ];
        final reply = await _channel.invokeMethod<Object?>('rescheduleAll', {
          'alarms': payload,
        });
        _absorbExactAlarmStatus(reply);
      } catch (e) {
        debugPrint('[ProactiveCare] alarm rescheduleAll failed: $e');
      }
    }
  }
}
