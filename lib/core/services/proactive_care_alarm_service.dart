import 'dart:io' show File, Platform;
import 'dart:math' as math;
import 'dart:ui' show IsolateNameServer;

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:image/image.dart' as img;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../utils/app_directories.dart';
import '../../utils/avatar_cache.dart';
import '../../utils/sandbox_path_resolver.dart';
import '../database/business_preferences.dart';
import '../database/business_preferences_store.dart';
import '../models/assistant.dart';
import '../models/conversation.dart';
import 'api/gemini_thought_signature.dart';
import 'logging/flutter_logger.dart';
import 'notification_service.dart';
import 'proactive_care_conversation_policy.dart';
import 'proactive_care_message_flow.dart';

/// Name of the main-isolate port that handles proactive care triggers while
/// the app process is alive. Registered by HomePageController on Android;
/// the alarm background isolate forwards a serializable trigger map to it.
const String proactiveCareMainPortName = 'cuplivo_proactive_care_main_port';

// User-visible only in the first-run edge where no l10n snapshot was saved
// yet (the snapshot is written on every app start, before any alarm can be
// scheduled through the UI).
const String _failureBodyFallback =
    'Failed to generate the proactive care message. Open Cuplivo for details.';

class ProactiveCareAlarmTrigger {
  const ProactiveCareAlarmTrigger({
    required this.conversationId,
    required this.expectedAtSeconds,
  });

  factory ProactiveCareAlarmTrigger.fromSchedule({
    required String conversationId,
    required DateTime expectedAt,
  }) => ProactiveCareAlarmTrigger(
    conversationId: conversationId,
    expectedAtSeconds:
        expectedAt.millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond,
  );

  factory ProactiveCareAlarmTrigger.fromMap(Map<Object?, Object?> map) {
    final conversationId = map['conversationId'];
    final expectedAtSeconds = map['expectedAtSeconds'];
    if (conversationId is! String ||
        conversationId.isEmpty ||
        expectedAtSeconds is! int) {
      throw const FormatException('invalid proactive care alarm trigger');
    }
    return ProactiveCareAlarmTrigger(
      conversationId: conversationId,
      expectedAtSeconds: expectedAtSeconds,
    );
  }

  final String conversationId;
  final int expectedAtSeconds;

  DateTime get expectedAt => DateTime.fromMillisecondsSinceEpoch(
    expectedAtSeconds * Duration.millisecondsPerSecond,
  );

  Map<String, Object> toMap() => <String, Object>{
    'conversationId': conversationId,
    'expectedAtSeconds': expectedAtSeconds,
  };
}

/// Background entrypoint invoked by android_alarm_manager_plus when a
/// proactive care alarm fires. It runs in a dedicated background isolate and
/// wakes the app whether it is in foreground, background, or killed.
@pragma('vm:entry-point')
Future<void> proactiveCareAlarmCallback(
  int id,
  Map<String, dynamic> params,
) async {
  WidgetsFlutterBinding.ensureInitialized();
  ProactiveCareAlarmTrigger trigger;
  try {
    trigger = ProactiveCareAlarmTrigger.fromMap(params);
  } catch (error) {
    debugPrint('[ProactiveCare] Invalid alarm payload (id=$id): $error');
    return;
  }
  debugPrint(
    '[ProactiveCare] Alarm fired (id=$id, '
    'conversationId=${trigger.conversationId}, '
    'expectedAt=${trigger.expectedAt.toIso8601String()})',
  );

  // App alive (foreground or background): send only isolate-serializable
  // primitives. The main isolate applies the same exact claim contract.
  if (_forwardToMainIsolate(trigger)) return;

  ProactiveCareHeadlessClaim? claim;
  try {
    claim = await ProactiveCareHeadlessChatStore.claimConversationSchedule(
      conversationId: trigger.conversationId,
      expectedAt: trigger.expectedAt,
    );
  } catch (error, stackTrace) {
    debugPrint(
      '[ProactiveCare] Conversation claim failed: $error\n$stackTrace',
    );
  }
  if (claim == null) {
    debugPrint(
      '[ProactiveCare] Schedule claim rejected for '
      '${trigger.conversationId}',
    );
    await ProactiveCareHeadlessChatStore.close();
    return;
  }

  // This isolate holds no state from the main isolate. Install its own
  // BusinessPreferences over SQLite, never SharedPreferences.
  sqlite.Database? preferencesDb;
  ProactiveCareMessageFlow flow;
  try {
    preferencesDb = await ProactiveCareHeadlessChatStore.openSharedSqlite();
    final prefs = BusinessPreferences.open(
      RawSqliteBusinessStore(preferencesDb),
    );
    await prefs.load();
    flow = ProactiveCareMessageFlow(preferences: prefs);
  } catch (error, stackTrace) {
    debugPrint(
      '[ProactiveCare] Business prefs open failed: $error\n$stackTrace',
    );
    preferencesDb?.close();
    preferencesDb = null;
    flow = ProactiveCareMessageFlow(
      preferences: await BusinessPreferences.memoryFallback(),
    );
  }

  try {
    await _runHeadlessCareFlow(claim, id, flow);
  } finally {
    await ProactiveCareHeadlessChatStore.close();
    preferencesDb?.close();
  }
  _forwardRefreshToMainIsolate(claim.conversation.id);
}

bool _forwardToMainIsolate(ProactiveCareAlarmTrigger trigger) {
  final port = IsolateNameServer.lookupPortByName(proactiveCareMainPortName);
  if (port == null) return false;
  debugPrint(
    '[ProactiveCare] App alive, forwarding ${trigger.conversationId} to main',
  );
  port.send(trigger.toMap());
  return true;
}

void _forwardRefreshToMainIsolate(String conversationId) {
  final port = IsolateNameServer.lookupPortByName(proactiveCareMainPortName);
  if (port == null) return;
  port.send(<String, Object>{
    'event': 'refresh',
    'conversationId': conversationId,
  });
}

/// Killed-process path: builds the full context from persisted settings and
/// SQLite, requests the care reply, appends it to the claimed conversation,
/// shows the notification, and decides that conversation's next care time.
Future<void> _runHeadlessCareFlow(
  ProactiveCareHeadlessClaim claim,
  int alarmId,
  ProactiveCareMessageFlow flow,
) async {
  final assistant = claim.assistant;
  final conversation = claim.conversation;
  final snapshot = await flow.loadL10nSnapshot();
  final failureBody = (snapshot?.failureNotificationBody.isNotEmpty ?? false)
      ? snapshot!.failureNotificationBody
      : _failureBodyFallback;

  String body;
  try {
    final modelCfg = await flow.loadModelConfigFromPrefs(assistant);
    if (modelCfg == null) {
      throw StateError('no chat model configured');
    }

    final fallbackThinkingBudget = await flow.loadThinkingBudgetFromPrefs();

    final careHistory = flow.buildHistory(
      conversation: conversation,
      messages: claim.messages,
      assistant: assistant,
      applySendRegexes: true,
      geminiThoughtSignatureForMessage: (messageId) =>
          claim.geminiThoughtSignaturesByMessageId[messageId],
    );
    final decisionHistory = flow.buildHistory(
      conversation: conversation,
      messages: claim.messages,
      assistant: assistant,
      applySendRegexes: false,
      geminiThoughtSignatureForMessage: (messageId) =>
          claim.geminiThoughtSignaturesByMessageId[messageId],
    );
    var recentChats = const <Conversation>[];
    if (assistant.enableRecentChatsReference) {
      try {
        recentChats =
            await ProactiveCareHeadlessChatStore.loadRecentChatReferencesFor(
              assistant.id,
              currentConversationId: conversation.id,
            );
      } catch (e) {
        debugPrint('[ProactiveCare] Recent chat references load failed: $e');
      }
    }

    final carePrompt = assistant.proactiveCarePrompt.trim().isNotEmpty
        ? assistant.proactiveCarePrompt
        : (snapshot?.carePromptDefault ?? '');
    final apiMessages = await flow.buildCareApiMessages(
      assistant: assistant,
      userNickname: await flow.loadUserNicknameFromPrefs(),
      modelId: modelCfg.modelId,
      history: careHistory,
      carePrompt: carePrompt,
      now: DateTime.now(),
      recentChats: recentChats,
      reloadWorldBooks: true,
    );

    final reply = await flow.requestCareReply(
      config: modelCfg.config,
      modelId: modelCfg.modelId,
      assistant: assistant,
      apiMessages: apiMessages,
      fallbackThinkingBudget: fallbackThinkingBudget,
    );
    if (reply.content.isEmpty) {
      throw StateError('model returned an empty proactive care reply');
    }

    final appended = await ProactiveCareHeadlessChatStore.appendAssistantReply(
      assistantId: assistant.id,
      conversationId: conversation.id,
      content: reply.content,
      modelId: modelCfg.modelId,
      providerId: modelCfg.providerKey,
      geminiThoughtSignature: reply.geminiThoughtSignature,
    );
    if (appended == null) {
      debugPrint(
        '[ProactiveCare] Exact conversation ${conversation.id} no longer '
        'eligible; dropping generated reply',
      );
      return;
    }
    body = reply.content;

    // Ask the decision model for the next care time (continuous care). A
    // failure here must not hide the reply that was already produced.
    try {
      final decisionCfg = await flow.loadDecisionModelConfigFromPrefs(
        assistant,
      );
      if (decisionCfg != null) {
        final decisionPrompt =
            assistant.proactiveCareDecisionPrompt.trim().isNotEmpty
            ? assistant.proactiveCareDecisionPrompt
            : (snapshot?.decisionPromptDefault ?? '');
        final newTime = await flow.decideNextCareTime(
          config: decisionCfg.config,
          modelId: decisionCfg.modelId,
          assistant: assistant,
          userNickname: await flow.loadUserNicknameFromPrefs(),
          history: <Map<String, dynamic>>[
            ...decisionHistory,
            {
              'role': 'assistant',
              'content': appendGeminiThoughtSignature(
                reply.content,
                reply.geminiThoughtSignature,
              ),
            },
          ],
          decisionPrompt: decisionPrompt,
          currentNextCareTime: null,
          fallbackThinkingBudget: fallbackThinkingBudget,
        );
        if (newTime != null) {
          final target =
              await ProactiveCareHeadlessChatStore.updateConversationNextTime(
                conversationId: conversation.id,
                assistantId: assistant.id,
                nextCareTime: newTime,
              );
          if (target != null) {
            await ProactiveCareAlarmService.initialize();
            await ProactiveCareAlarmService.sync(
              conversation: target.conversation,
              assistant: target.assistant,
            );
          } else {
            debugPrint(
              '[ProactiveCare] Failed to persist next care time for '
              '${conversation.id}',
            );
          }
        } else {
          debugPrint(
            '[ProactiveCare] Headless decision returned no next time for '
            '${conversation.id}; consumed schedule remains null',
          );
        }
      }
    } catch (e) {
      debugPrint('[ProactiveCare] Next-time decision failed: $e');
    }
  } catch (e) {
    debugPrint('[ProactiveCare] Headless care flow failed: $e');
    body = failureBody;
  }

  final iconPath = await resolveProactiveCareNotificationIconPath(
    assistant,
    alarmId,
  );
  try {
    await NotificationService.showProactiveCare(
      id: alarmId,
      conversationId: conversation.id,
      title: assistant.name,
      body: body,
      largeIconPath: iconPath,
    );
    debugPrint(
      '[ProactiveCare] Notification shown for ${assistant.id} '
      '(icon=${iconPath ?? 'none'})',
    );
  } catch (e) {
    debugPrint('[ProactiveCare] Failed to show notification: $e');
  }
}

/// Resolves the assistant avatar to a local PNG usable as the notification
/// large icon. Returns null for emoji/initial avatars or on failure (the
/// notification then falls back to the app's default icon).
Future<String?> resolveProactiveCareNotificationIconPath(
  Assistant assistant,
  int alarmId,
) async {
  final avatar = assistant.avatar?.trim() ?? '';
  if (avatar.isEmpty) return null;

  String? sourcePath;
  try {
    if (avatar.startsWith('http://') || avatar.startsWith('https://')) {
      sourcePath = await AvatarCache.getPath(avatar);
    } else if (avatar.startsWith('/') || avatar.contains(':')) {
      await SandboxPathResolver.init();
      final fixed = SandboxPathResolver.fix(avatar);
      if (File(fixed).existsSync()) sourcePath = fixed;
    } else {
      // Emoji or initial-letter avatar: no bitmap to show.
      return null;
    }
  } catch (e) {
    debugPrint('[ProactiveCare] Avatar resolve failed: $e');
    return null;
  }
  if (sourcePath == null) {
    debugPrint('[ProactiveCare] Avatar file unavailable for $avatar');
    return null;
  }

  try {
    final bytes = await File(sourcePath).readAsBytes();
    final png = cropAvatarForNotification(bytes);
    if (png == null) {
      debugPrint('[ProactiveCare] Avatar decode failed for $sourcePath');
      return null;
    }
    final dir = await AppDirectories.getCacheDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final out = File('${dir.path}/proactive_care_icon_$alarmId.png');
    await out.writeAsBytes(png, flush: true);
    return out.path;
  } catch (e) {
    debugPrint('[ProactiveCare] Avatar crop failed: $e');
    return null;
  }
}

/// Center-crops [bytes] to a square (no stretching), resizes it down to at
/// most [maxSize] px, applies a circular mask, and returns the PNG bytes.
/// Returns null when the input cannot be decoded as an image.
@visibleForTesting
Uint8List? cropAvatarForNotification(Uint8List bytes, {int maxSize = 256}) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    return null;
  }
  if (decoded == null) return null;
  final side = math.min(decoded.width, decoded.height);
  var square = img.copyCrop(
    decoded,
    x: (decoded.width - side) ~/ 2,
    y: (decoded.height - side) ~/ 2,
    width: side,
    height: side,
  );
  if (side > maxSize) {
    square = img.copyResize(
      square,
      width: maxSize,
      height: maxSize,
      interpolation: img.Interpolation.average,
    );
  }
  final circled = img.copyCropCircle(square.convert(numChannels: 4));
  return img.encodePng(circled);
}

/// Schedules Android exact alarms ("setExactAndAllowWhileIdle") that wake the
/// app when an assistant's proactive care time arrives.
///
/// All methods are no-ops on non-Android platforms.
class ProactiveCareAlarmService {
  const ProactiveCareAlarmService._();

  static const String _logTag = 'ProactiveCareAlarm';

  /// Whether proactive care (exact alarms + wake-up) is available on this device.
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static bool get _isAndroid => isSupported;

  /// Starts the AlarmManager service. Must be called once before scheduling
  /// alarms (done in `main()` before `runApp`).
  static Future<void> initialize() async {
    if (!_isAndroid) return;
    try {
      final ok = await AndroidAlarmManager.initialize();
      if (!ok) {
        debugPrint('[ProactiveCare] AndroidAlarmManager.initialize false');
        FlutterLogger.log(
          'AndroidAlarmManager.initialize returned false',
          tag: _logTag,
        );
      }
    } catch (e) {
      debugPrint('[ProactiveCare] AlarmManager initialize failed: $e');
      FlutterLogger.log('AlarmManager initialize failed: $e', tag: _logTag);
    }
  }

  /// Derives a stable 31-bit positive alarm id from [conversationId] using
  /// FNV-1a. `String.hashCode` is not guaranteed to be stable across runs,
  /// while the id must stay identical to cancel/replace a pending alarm.
  static int alarmIdFor(String conversationId) {
    const int fnvPrime = 0x01000193;
    int hash = 0x811c9dc5; // FNV offset basis
    for (final unit in conversationId.codeUnits) {
      hash ^= unit;
      hash = (hash * fnvPrime) & 0xFFFFFFFF;
    }
    return hash & 0x7FFFFFFF;
  }

  /// Resolves future, effectively enabled schedules from persisted
  /// conversations and their fixed owner assistants.
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

  /// Schedules or cancels the exact alarm for one explicit conversation-owner
  /// pair. This method never requests permissions.
  static Future<void> sync({
    required Conversation conversation,
    required Assistant assistant,
  }) async {
    if (!_isAndroid) return;
    final at = conversation.proactiveCareNextMessageAt;
    final id = alarmIdFor(conversation.id);
    try {
      if (!ProactiveCareConversationPolicy.isEligible(
            conversation,
            assistant,
          ) ||
          at == null ||
          !at.isAfter(DateTime.now())) {
        await AndroidAlarmManager.cancel(id);
        return;
      }
      final ok = await AndroidAlarmManager.oneShotAt(
        at,
        id,
        proactiveCareAlarmCallback,
        exact: true,
        wakeup: true,
        allowWhileIdle: true,
        rescheduleOnReboot: true,
        params: ProactiveCareAlarmTrigger.fromSchedule(
          conversationId: conversation.id,
          expectedAt: at,
        ).toMap(),
      );
      if (ok) {
        debugPrint(
          '[ProactiveCare] Alarm scheduled for ${conversation.id} at '
          '${at.toIso8601String()} (id=$id)',
        );
      } else {
        debugPrint(
          '[ProactiveCare] Alarm schedule FAILED for ${conversation.id} at '
          '${at.toIso8601String()} (id=$id)',
        );
      }
      FlutterLogger.log(
        'Alarm ${ok ? 'scheduled' : 'schedule FAILED'} for conversation '
        '${conversation.id} at ${at.toIso8601String()} (id=$id)',
        tag: _logTag,
      );
    } catch (e) {
      debugPrint(
        '[ProactiveCare] Alarm sync failed for ${conversation.id}: $e',
      );
      FlutterLogger.log(
        'Alarm sync failed for conversation ${conversation.id}: $e',
        tag: _logTag,
      );
    }
  }

  /// Cancels the pending alarm for [conversationId], if any.
  static Future<void> cancelFor(String conversationId) async {
    if (!_isAndroid) return;
    try {
      await AndroidAlarmManager.cancel(alarmIdFor(conversationId));
    } catch (e) {
      debugPrint('[ProactiveCare] Alarm cancel failed for $conversationId: $e');
      FlutterLogger.log(
        'Alarm cancel failed for conversation $conversationId: $e',
        tag: _logTag,
      );
    }
  }

  /// Re-schedules persisted, eligible conversation schedules on app startup.
  static Future<void> rescheduleAll({
    required List<Conversation> conversations,
    required List<Assistant> assistants,
  }) async {
    if (!_isAndroid) return;
    final pending = pendingForReschedule(
      conversations: conversations,
      assistants: assistants,
    );
    debugPrint(
      '[ProactiveCare] rescheduleAll: ${pending.length}/'
      '${conversations.length} conversations need re-arming',
    );
    // sync() never throws (all failures are caught and logged inside), so no
    // per-assistant try/catch is needed here.
    for (final target in pending) {
      await sync(
        conversation: target.conversation,
        assistant: target.assistant,
      );
    }
  }
}
