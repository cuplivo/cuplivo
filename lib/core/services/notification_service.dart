import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

typedef ChatCompletionNotificationSender =
    Future<void> Function({
      required String conversationId,
      String? title,
      String? body,
    });

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static final StreamController<String> _conversationTapController =
      StreamController<String>.broadcast();
  static final StreamController<String> _scheduledRunTapController =
      StreamController<String>.broadcast();
  static String? _pendingScheduledRunId;
  static Stream<String> get scheduledRunTaps =>
      _scheduledRunTapController.stream;
  static String? takePendingScheduledRunId() {
    final id = _pendingScheduledRunId;
    _pendingScheduledRunId = null;
    return id;
  }

  static bool _inited = false;
  static Future<void>? _initialization;
  static String? _pendingConversationId;
  static final Map<String, String> _pendingMessageIds = {};
  static String? takePendingMessageId(String conversationId) =>
      _pendingMessageIds.remove(conversationId);
  static const String _chatCompletionPayloadPrefix = 'chat-complete:';
  static const String _proactiveCarePayloadPrefix = 'proactive-care:';
  static const String proactiveCareNotificationChannelId =
      'cuplivo_proactive_care';
  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'cuplivo_bg_chat_v2',
    'Chat Background',
    description: 'Notifications for chat generation status',
    importance: Importance.high,
    playSound: true,
  );

  static const AndroidNotificationChannel _proactiveCareChannel =
      AndroidNotificationChannel(
        proactiveCareNotificationChannelId,
        'Proactive Care',
        description: 'Proactive care messages from assistants',
        importance: Importance.high,
        playSound: true,
      );

  static Stream<String> get conversationTaps =>
      _conversationTapController.stream;

  /// Returns a notification target received before the home page subscribed.
  static String? takePendingConversationId() {
    final conversationId = _pendingConversationId;
    _pendingConversationId = null;
    return conversationId;
  }

  static Future<void> ensureInitialized() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    if (_inited) return;
    final existing = _initialization;
    if (existing != null) {
      await existing;
      return;
    }

    final initialization = _initializeAndroid();
    _initialization = initialization;
    try {
      await initialization;
    } finally {
      if (identical(_initialization, initialization)) {
        _initialization = null;
      }
    }
  }

  static Future<void> _initializeAndroid() async {
    // Android initialization
    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@drawable/ic_background_generation');
    const InitializationSettings init = InitializationSettings(
      android: androidInit,
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(
      init,
      onDidReceiveNotificationResponse: _handleNotificationResponse,
    );

    // Create channel
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      await android.createNotificationChannel(_channel);
      await android.createNotificationChannel(_proactiveCareChannel);
      // Runtime notification permission (Android 13+) should be requested by app UI if needed
    }
    _inited = true;

    // The response callback covers warm starts. Cold starts must be queried
    // explicitly after plugin initialization.
    try {
      final launchDetails = await _plugin.getNotificationAppLaunchDetails();
      if (launchDetails?.didNotificationLaunchApp == true) {
        final response = launchDetails?.notificationResponse;
        if (response != null) _handleNotificationResponse(response);
      }
    } catch (_) {}
  }

  /// Ensure Android 13+ notifications permission is granted (no-op on lower versions/other platforms).
  static Future<bool> ensureAndroidNotificationsPermission() async {
    if (!Platform.isAndroid) return true;
    await ensureInitialized();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return true;
    try {
      final enabled = await android.areNotificationsEnabled();
      if (enabled == true) return true;
    } catch (_) {}
    try {
      final ok = await android.requestNotificationsPermission();
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> showChatCompleted({
    required String conversationId,
    String? title,
    String? body,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    if (conversationId.trim().isEmpty) return;
    await ensureInitialized();
    await _plugin.show(
      notificationIdForConversation(conversationId),
      title ?? 'Generation complete',
      body ?? 'Assistant reply has been generated',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.public,
          ticker: 'Cuplivo',
          styleInformation: BigTextStyleInformation(
            body ?? 'Assistant reply has been generated',
          ),
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          threadIdentifier: 'cuplivo.chat-completion',
        ),
      ),
      payload: '$_chatCompletionPayloadPrefix$conversationId',
    );
  }

  /// A proactive care ("Ta的来信") letter. Same routing as chat
  /// completion: tapping opens the conversation.
  static Future<void> showProactiveCareLetter({
    int? id,
    required String conversationId,
    required String title,
    required String body,
    String? largeIconPath,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    if (conversationId.trim().isEmpty) return;
    await ensureInitialized();
    final style = BigTextStyleInformation(body);
    await _plugin.show(
      id ?? proactiveCareIdFor(conversationId),
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _proactiveCareChannel.id,
          _proactiveCareChannel.name,
          channelDescription: _proactiveCareChannel.description,
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.public,
          ticker: 'Cuplivo',
          styleInformation: style,
          largeIcon: (largeIconPath == null || largeIconPath.isEmpty)
              ? null
              : FilePathAndroidBitmap(largeIconPath),
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          threadIdentifier: 'cuplivo.proactive-care',
        ),
      ),
      payload: '$_proactiveCarePayloadPrefix$conversationId',
    );
  }

  static void _handleNotificationResponse(NotificationResponse response) {
    final runId = scheduledRunIdFromPayload(response.payload);
    if (runId != null) {
      if (_scheduledRunTapController.hasListener) {
        _scheduledRunTapController.add(runId);
      } else {
        _pendingScheduledRunId = runId;
      }
      return;
    }
    final conversationId = conversationIdFromPayload(response.payload);
    if (conversationId == null) return;
    openConversation(conversationId);
  }

  /// Also receives taps from the native ongoing notification, overlay and
  /// ActivityKit. Keep the target until the home route has initialized.
  static void openConversation(String conversationId, {String? messageId}) {
    if (messageId != null) _pendingMessageIds[conversationId] = messageId;
    if (conversationId.trim().isEmpty) return;
    if (_conversationTapController.hasListener) {
      _conversationTapController.add(conversationId);
    } else {
      _pendingConversationId = conversationId;
    }
  }

  @visibleForTesting
  static String? conversationIdFromPayload(String? payload) {
    final conversationId = _conversationIdFromPrefixedPayload(
      payload,
      _chatCompletionPayloadPrefix,
    );
    if (conversationId != null) return conversationId;
    return _conversationIdFromPrefixedPayload(
      payload,
      _proactiveCarePayloadPrefix,
    );
  }

  static String? _conversationIdFromPrefixedPayload(
    String? payload,
    String prefix,
  ) {
    if (payload == null || !payload.startsWith(prefix)) {
      return null;
    }
    final conversationId = payload.substring(prefix.length).trim();
    return conversationId.isEmpty ? null : conversationId;
  }

  @visibleForTesting
  static String? scheduledRunIdFromPayload(String? payload) {
    const prefix = 'scheduled-task:';
    if (payload == null || !payload.startsWith(prefix)) return null;
    final id = payload.substring(prefix.length).trim();
    return id.isEmpty ? null : id;
  }

  static int _fnv1aId(String key, int baseId) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(key)) {
      hash = ((hash ^ byte) * 0x01000193) & 0x7fffffff;
    }
    return baseId + (hash % (0x7fffffff - baseId));
  }

  /// Stable per-conversation IDs let notifications from different chats
  /// coexist while a later completion in the same chat replaces the old one.
  @visibleForTesting
  static int notificationIdForConversation(String conversationId) =>
      _fnv1aId(conversationId, 10000);

  /// Stable conversation-owned id for proactive care letters. Kept in a
  /// distinct space from [notificationIdForConversation] so a letter never
  /// replaces (or is replaced by) a chat-completion notification of the
  /// same conversation.
  static int proactiveCareIdFor(String conversationId) =>
      _fnv1aId(conversationId, 30000);
}
