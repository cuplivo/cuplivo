import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const proactiveCareNotificationChannelId = 'cuplivo_proactive_care';
const proactiveCareNotificationPayloadType = 'proactiveCare';
const proactiveCareNotificationPayloadVersion = 1;

enum ProactiveCareNotificationPayloadKind {
  proactiveCare,
  nonProactive,
  malformed,
}

class ProactiveCareNotificationPayloadResult {
  const ProactiveCareNotificationPayloadResult._(
    this.kind, [
    this.conversationId,
  ]);

  const ProactiveCareNotificationPayloadResult.proactiveCare(
    String conversationId,
  ) : this._(
        ProactiveCareNotificationPayloadKind.proactiveCare,
        conversationId,
      );

  const ProactiveCareNotificationPayloadResult.nonProactive()
    : this._(ProactiveCareNotificationPayloadKind.nonProactive);

  const ProactiveCareNotificationPayloadResult.malformed()
    : this._(ProactiveCareNotificationPayloadKind.malformed);

  final ProactiveCareNotificationPayloadKind kind;
  final String? conversationId;
}

String buildProactiveCareNotificationPayload(String conversationId) =>
    jsonEncode(<String, Object>{
      'type': proactiveCareNotificationPayloadType,
      'version': proactiveCareNotificationPayloadVersion,
      'conversationId': conversationId,
    });

ProactiveCareNotificationPayloadResult parseProactiveCareNotificationPayload(
  String? payload,
) {
  if (payload == null || payload.trim().isEmpty) {
    return const ProactiveCareNotificationPayloadResult.malformed();
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } catch (_) {
    return const ProactiveCareNotificationPayloadResult.malformed();
  }
  if (decoded is! Map<String, dynamic>) {
    return const ProactiveCareNotificationPayloadResult.malformed();
  }

  final type = decoded['type'];
  if (type is! String) {
    return const ProactiveCareNotificationPayloadResult.malformed();
  }
  if (type != proactiveCareNotificationPayloadType) {
    return const ProactiveCareNotificationPayloadResult.nonProactive();
  }

  final conversationId = decoded['conversationId'];
  if (decoded['version'] != proactiveCareNotificationPayloadVersion ||
      conversationId is! String ||
      conversationId.trim().isEmpty) {
    return const ProactiveCareNotificationPayloadResult.malformed();
  }
  return ProactiveCareNotificationPayloadResult.proactiveCare(conversationId);
}

class ProactiveCareNotificationTargetBuffer {
  String? _pendingConversationId;
  Object? _consumerOwner;
  void Function(String conversationId)? _consumer;

  String? get pendingConversationId => _pendingConversationId;

  void add(String conversationId) {
    final consumer = _consumer;
    if (consumer == null) {
      _pendingConversationId = conversationId;
      return;
    }
    consumer(conversationId);
  }

  void attach(Object owner, void Function(String conversationId) consumer) {
    _consumerOwner = owner;
    _consumer = consumer;
    final pending = _pendingConversationId;
    _pendingConversationId = null;
    if (pending != null) consumer(pending);
  }

  void detach(Object owner) {
    if (!identical(_consumerOwner, owner)) return;
    _consumerOwner = null;
    _consumer = null;
  }
}

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static final ProactiveCareNotificationTargetBuffer proactiveCareTargets =
      ProactiveCareNotificationTargetBuffer();
  static bool _inited = false;
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

  static Future<void> ensureInitialized() async {
    if (!Platform.isAndroid) return;
    if (_inited) return;

    // Android initialization
    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings init = InitializationSettings(
      android: androidInit,
    );
    await _plugin.initialize(
      init,
      onDidReceiveNotificationResponse: _handleNotificationResponse,
    );

    // Create channels
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      await android.createNotificationChannel(_channel);
      await android.createNotificationChannel(_proactiveCareChannel);
    }
    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp == true) {
      final response = launchDetails?.notificationResponse;
      if (response != null) _handleNotificationResponse(response);
    }
    _inited = true;
  }

  static void _handleNotificationResponse(NotificationResponse response) {
    final parsed = parseProactiveCareNotificationPayload(response.payload);
    switch (parsed.kind) {
      case ProactiveCareNotificationPayloadKind.proactiveCare:
        proactiveCareTargets.add(parsed.conversationId!);
        return;
      case ProactiveCareNotificationPayloadKind.nonProactive:
        debugPrint(
          '[NotificationService] Ignoring non-proactive notification payload',
        );
        return;
      case ProactiveCareNotificationPayloadKind.malformed:
        debugPrint(
          '[NotificationService] Ignoring malformed notification payload',
        );
        return;
    }
  }

  /// Ensure Android 13+ notifications permission is granted (no-op on lower versions/other platforms).
  static Future<bool> ensureAndroidNotificationsPermission() async {
    if (!Platform.isAndroid) return true;
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

  /// Shows a proactive care notification on behalf of an assistant.
  ///
  /// [id] should be stable per assistant (e.g. derived from the assistant id)
  /// so a newer notification replaces the previous one instead of piling up.
  /// [title] is the assistant name, [body] the message text (the LLM reply),
  /// and [largeIconPath] an optional local image file shown as the
  /// notification's large icon.
  static Future<void> showProactiveCare({
    required int id,
    required String conversationId,
    required String title,
    required String body,
    String? largeIconPath,
  }) async {
    if (!Platform.isAndroid) return;
    await ensureInitialized();
    await _plugin.show(
      id,
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
          largeIcon: largeIconPath == null
              ? null
              : FilePathAndroidBitmap(largeIconPath),
          styleInformation: BigTextStyleInformation(body),
        ),
      ),
      payload: buildProactiveCareNotificationPayload(conversationId),
    );
  }

  static Future<void> showChatCompleted({String? title, String? body}) async {
    if (!Platform.isAndroid) return;
    await ensureInitialized();
    await _plugin.show(
      2001, // id
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
          styleInformation: const DefaultStyleInformation(true, true),
        ),
      ),
    );
  }
}
