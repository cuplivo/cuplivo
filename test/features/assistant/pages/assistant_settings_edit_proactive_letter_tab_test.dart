import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/android_proactive_care_settings_service.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/notification_service.dart';
import 'package:Cuplivo/features/assistant/pages/assistant_settings_edit_page.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/ios_expandable_section.dart';
import 'package:Cuplivo/shared/widgets/ios_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_sliders/sliders.dart';

const _assistantId = 'assistant-proactive-tab-test';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    'assistant switch changes only the default and prompts stay visible',
    (tester) async {
      final legacyTime = DateTime(2035, 1, 2, 3, 4);
      final platform = _FakeAndroidSettingsPlatform();
      final fixture = await _pumpTab(
        tester,
        assistant: Assistant(
          id: _assistantId,
          name: 'Assistant',
          enableProactiveCare: false,
          proactiveCareNextMessageAt: legacyTime,
        ),
        chatService: _FakeChatService(),
        platform: platform,
      );

      expect(find.byType(IosExpandableSection), findsNWidgets(2));
      expect(find.text('Proactive care prompt'), findsOneWidget);
      expect(find.text('Decision time instruction prompt'), findsOneWidget);
      expect(find.text('Next proactive message time'), findsNothing);

      await tester.tap(find.byType(IosSwitch));
      await tester.pump();

      var updated = fixture.assistantProvider.getById(_assistantId)!;
      expect(updated.enableProactiveCare, isTrue);
      expect(updated.proactiveCareNextMessageAt, legacyTime);
      expect(platform.requestNotificationCalls, 0);
      expect(platform.requestExactAlarmCalls, 0);
      expect(platform.requestBatteryCalls, 0);
      expect(platform.settingsCalls, isEmpty);

      await tester.tap(find.byType(IosSwitch));
      await tester.pump();

      updated = fixture.assistantProvider.getById(_assistantId)!;
      expect(updated.enableProactiveCare, isFalse);
      expect(updated.proactiveCareNextMessageAt, legacyTime);
      expect(find.text('Proactive care prompt'), findsOneWidget);
      expect(find.text('Decision time instruction prompt'), findsOneWidget);
    },
  );

  testWidgets(
    'conversation section filters overrides and drafts and sorts schedule groups',
    (tester) async {
      final now = DateTime.now();
      final conversations = <Conversation>[
        _conversation(
          id: 'late',
          title: 'Future late',
          nextAt: now.add(const Duration(days: 2)),
        ),
        _conversation(id: 'unset', title: 'Unset inherited'),
        _conversation(
          id: 'expired',
          title: 'Expired inherited',
          nextAt: now.subtract(const Duration(days: 1)),
        ),
        _conversation(
          id: 'early',
          title: 'Future early explicit',
          enabledOverride: true,
          nextAt: now.add(const Duration(days: 1)),
        ),
        _conversation(
          id: 'off',
          title: 'Explicitly disabled',
          enabledOverride: false,
        ),
        _conversation(
          id: 'other',
          title: 'Other assistant',
          assistantId: 'other-assistant',
        ),
        _conversation(
          id: 'group',
          title: 'Group conversation',
          kind: Conversation.kindGroup,
        ),
        _conversation(id: 'draft', title: 'Draft conversation'),
      ];
      final chatService = _FakeChatService(
        conversations: conversations,
        draftIds: const <String>{'draft'},
      );
      final fixture = await _pumpTab(
        tester,
        assistant: Assistant(
          id: _assistantId,
          name: 'Assistant',
          enableProactiveCare: true,
        ),
        chatService: chatService,
      );

      expect(find.text('Future early explicit'), findsNothing);
      await tester.tap(find.text('Conversation next-letter times'));
      await tester.pumpAndSettle();

      expect(find.text('Future early explicit'), findsOneWidget);
      expect(find.text('Future late'), findsOneWidget);
      expect(find.text('Expired inherited'), findsOneWidget);
      expect(find.text('Unset inherited'), findsOneWidget);
      expect(find.text('Explicitly disabled'), findsNothing);
      expect(find.text('Other assistant'), findsNothing);
      expect(find.text('Group conversation'), findsNothing);
      expect(find.text('Draft conversation'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Future early explicit')).dy,
        lessThan(tester.getTopLeft(find.text('Future late')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Future late')).dy,
        lessThan(tester.getTopLeft(find.text('Expired inherited')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Expired inherited')).dy,
        lessThan(tester.getTopLeft(find.text('Unset inherited')).dy),
      );
      expect(find.textContaining('Future ·'), findsNWidgets(2));
      expect(find.textContaining('Expired ·'), findsOneWidget);
      expect(find.text('Unset'), findsOneWidget);

      await tester.tap(
        find.byKey(
          const ValueKey('assistant-proactive-conversation-clear-early'),
        ),
      );
      await tester.pumpAndSettle();
      expect(chatService.timeUpdates, <(String, DateTime?)>[('early', null)]);
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey('assistant-proactive-conversation-early'),
          ),
          matching: find.text('Unset'),
        ),
        findsOneWidget,
      );

      await fixture.assistantProvider.updateAssistant(
        fixture.assistantProvider
            .getById(_assistantId)!
            .copyWith(enableProactiveCare: false),
      );
      await tester.pump();
      expect(find.text('Future early explicit'), findsOneWidget);
      expect(find.text('Future late'), findsNothing);
      expect(find.text('Expired inherited'), findsNothing);
      expect(find.text('Unset inherited'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('assistant-proactive-conversation-early')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Choose date and time'), findsOneWidget);
    },
  );

  testWidgets(
    'decision history limit transitions between unlimited and count',
    (tester) async {
      final fixture = await _pumpTab(
        tester,
        assistant: Assistant(id: _assistantId, name: 'Assistant'),
        chatService: _FakeChatService(),
      );
      const rowKey = ValueKey('assistant-proactive-decision-history-limit');

      expect(find.text('Messages used for time decisions'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(rowKey),
          matching: find.text('Disabled (no restrictions)'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(rowKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(IosSwitch).last);
      await tester.pumpAndSettle();

      expect(
        fixture.assistantProvider
            .getById(_assistantId)!
            .proactiveCareDecisionHistoryMessageLimit,
        Assistant.defaultContextMessageSize,
      );
      expect(
        find.descendant(of: find.byKey(rowKey), matching: find.text('64')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(rowKey));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(SfSlider), const Offset(120, 0));
      await tester.pump(const Duration(milliseconds: 600));
      final changedLimit = fixture.assistantProvider
          .getById(_assistantId)!
          .proactiveCareDecisionHistoryMessageLimit;
      expect(changedLimit, isNotNull);
      expect(changedLimit, isNot(Assistant.defaultContextMessageSize));
      expect(
        changedLimit,
        inInclusiveRange(
          Assistant.minContextMessageSize,
          Assistant.maxContextMessageSize,
        ),
      );

      await tester.tap(find.byType(IosSwitch).last);
      await tester.pumpAndSettle();
      expect(
        fixture.assistantProvider
            .getById(_assistantId)!
            .proactiveCareDecisionHistoryMessageLimit,
        isNull,
      );
    },
  );

  testWidgets('shared limit sheet preserves a disabled basic context value', (
    tester,
  ) async {
    final fixture = await _pumpTab(
      tester,
      assistant: Assistant(
        id: _assistantId,
        name: 'Assistant',
        contextMessageSize: 128,
        limitContextMessages: false,
      ),
      chatService: _FakeChatService(),
      home: const AssistantSettingsEditPage(assistantId: _assistantId),
    );

    await tester.tap(find.text('Context Messages'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(IosSwitch).last);
    await tester.pumpAndSettle();

    final assistant = fixture.assistantProvider.getById(_assistantId)!;
    expect(assistant.limitContextMessages, isTrue);
    expect(assistant.contextMessageSize, 128);
  });

  testWidgets(
    'permission section combines readiness and acts only on explicit row taps',
    (tester) async {
      final platform = _FakeAndroidSettingsPlatform(
        notificationsEnabled: false,
        channelImportance: Importance.none,
        exactAlarmStatusValue: PermissionStatus.denied,
        batteryStatusValue: PermissionStatus.denied,
        throwOnFirstExactQuery: true,
      );
      await _pumpTab(
        tester,
        assistant: Assistant(id: _assistantId, name: 'Assistant'),
        chatService: _FakeChatService(),
        platform: platform,
      );

      expect(platform.requestNotificationCalls, 0);
      expect(platform.requestExactAlarmCalls, 0);
      expect(platform.requestBatteryCalls, 0);
      expect(platform.settingsCalls, isEmpty);

      await tester.tap(find.text('Android readiness'));
      await tester.pumpAndSettle();

      expect(find.text('Required'), findsNWidgets(2));
      expect(find.text('Recommended'), findsNWidgets(2));
      expect(_statusText(tester, 'notifications'), 'Tap to grant');
      expect(_statusText(tester, 'exactAlarm'), 'Unknown');
      expect(_statusText(tester, 'autoStart'), 'Manual');
      expect(_statusText(tester, 'battery'), 'Tap to grant');

      await tester.tap(
        find.byKey(
          const ValueKey('assistant-proactive-permission-notifications'),
        ),
      );
      await tester.pumpAndSettle();
      expect(platform.requestNotificationCalls, 1);
      expect(platform.settingsCalls, isEmpty);
      expect(_statusText(tester, 'notifications'), 'Tap to grant');

      await tester.tap(
        find.byKey(
          const ValueKey('assistant-proactive-permission-notifications'),
        ),
      );
      await tester.pumpAndSettle();
      expect(platform.requestNotificationCalls, 1);
      expect(
        platform.settingsCalls,
        contains('openNotificationChannelSettings'),
      );

      platform.channelImportance = Importance.high;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(_statusText(tester, 'notifications'), 'Ready');

      await tester.tap(
        find.byKey(const ValueKey('assistant-proactive-permission-exactAlarm')),
      );
      await tester.pumpAndSettle();
      expect(platform.requestExactAlarmCalls, 1);
      expect(_statusText(tester, 'exactAlarm'), 'Ready');

      await tester.tap(
        find.byKey(const ValueKey('assistant-proactive-permission-autoStart')),
      );
      await tester.pumpAndSettle();
      expect(platform.settingsCalls, contains('openAutoStartSettings'));
      expect(_statusText(tester, 'autoStart'), 'Manual');

      await tester.tap(
        find.byKey(const ValueKey('assistant-proactive-permission-battery')),
      );
      await tester.pumpAndSettle();
      expect(platform.requestBatteryCalls, 1);
      expect(_statusText(tester, 'battery'), 'Ready');
      expect(platform.notificationStatusQueries, greaterThan(5));
    },
  );

  testWidgets('notification denial opens app notification settings', (
    tester,
  ) async {
    final platform = _FakeAndroidSettingsPlatform(
      notificationsEnabled: false,
      requestNotificationsGrants: false,
    );
    await _pumpTab(
      tester,
      assistant: Assistant(id: _assistantId, name: 'Assistant'),
      chatService: _FakeChatService(),
      platform: platform,
    );

    await tester.tap(find.text('Android readiness'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey('assistant-proactive-permission-notifications'),
      ),
    );
    await tester.pumpAndSettle();

    expect(platform.requestNotificationCalls, 1);
    expect(platform.settingsCalls, contains('openAppNotificationSettings'));
  });
}

String _statusText(WidgetTester tester, String keyName) => tester
    .widget<Text>(
      find.byKey(ValueKey('assistant-proactive-permission-status-$keyName')),
    )
    .data!;

Conversation _conversation({
  required String id,
  required String title,
  String assistantId = _assistantId,
  String kind = Conversation.kindNormal,
  bool? enabledOverride,
  DateTime? nextAt,
}) => Conversation(
  id: id,
  title: title,
  assistantId: assistantId,
  conversationKind: kind,
  proactiveCareEnabledOverride: enabledOverride,
  proactiveCareNextMessageAt: nextAt,
);

Future<_TabFixture> _pumpTab(
  WidgetTester tester, {
  required Assistant assistant,
  required _FakeChatService chatService,
  _FakeAndroidSettingsPlatform? platform,
  Widget? home,
}) async {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final preferences = BusinessPreferences.memoryForTests();
  final sharedPreferences = await SharedPreferences.getInstance();
  await sharedPreferences.setString(
    'assistants_v1',
    Assistant.encodeList(<Assistant>[assistant]),
  );
  final assistantProvider = AssistantProvider(preferences: preferences);
  await assistantProvider.loadFromPrefs();
  final settingsPlatform = platform ?? _FakeAndroidSettingsPlatform();

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<BusinessPreferences>.value(value: preferences),
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(preferences: preferences),
        ),
        ChangeNotifierProvider<ChatService>.value(value: chatService),
        ChangeNotifierProvider.value(value: assistantProvider),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home:
            home ??
            Scaffold(
              body: AssistantProactiveLetterTab(
                assistantId: _assistantId,
                settingsService: AndroidProactiveCareSettingsService(
                  platform: settingsPlatform,
                ),
              ),
            ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _TabFixture(assistantProvider: assistantProvider);
}

class _TabFixture {
  const _TabFixture({required this.assistantProvider});

  final AssistantProvider assistantProvider;
}

class _FakeChatService extends ChatService {
  _FakeChatService({List<Conversation>? conversations, Set<String>? draftIds})
    : conversations = conversations ?? <Conversation>[],
      draftIds = draftIds ?? <String>{};

  final List<Conversation> conversations;
  final Set<String> draftIds;
  final List<(String, DateTime?)> timeUpdates = <(String, DateTime?)>[];

  @override
  bool get initialized => true;

  @override
  List<Conversation> getAllConversations({bool includeGroup = false}) =>
      List<Conversation>.of(conversations);

  @override
  bool isDraftConversation(String? id) => id != null && draftIds.contains(id);

  @override
  Future<void> setConversationProactiveCareNextMessageAt(
    String conversationId,
    DateTime? value,
  ) async {
    timeUpdates.add((conversationId, value));
    final index = conversations.indexWhere(
      (conversation) => conversation.id == conversationId,
    );
    conversations[index] = conversations[index].copyWith(
      proactiveCareNextMessageAt: value,
      clearProactiveCareNextMessageAt: value == null,
    );
    notifyListeners();
  }
}

class _FakeAndroidSettingsPlatform
    implements AndroidProactiveCareSettingsPlatform {
  _FakeAndroidSettingsPlatform({
    this.notificationsEnabled = true,
    this.channelImportance = Importance.high,
    this.exactAlarmStatusValue = PermissionStatus.granted,
    this.batteryStatusValue = PermissionStatus.granted,
    this.throwOnFirstExactQuery = false,
    this.requestNotificationsGrants = true,
  });

  bool notificationsEnabled;
  Importance channelImportance;
  PermissionStatus exactAlarmStatusValue;
  PermissionStatus batteryStatusValue;
  bool throwOnFirstExactQuery;
  bool requestNotificationsGrants;

  int notificationStatusQueries = 0;
  int requestNotificationCalls = 0;
  int requestExactAlarmCalls = 0;
  int requestBatteryCalls = 0;
  final List<String> settingsCalls = <String>[];

  @override
  bool get isAndroid => true;

  @override
  Future<bool?> areNotificationsEnabled() async {
    notificationStatusQueries++;
    return notificationsEnabled;
  }

  @override
  Future<bool?> requestNotifications() async {
    requestNotificationCalls++;
    if (requestNotificationsGrants) notificationsEnabled = true;
    return requestNotificationsGrants;
  }

  @override
  Future<PermissionStatus> exactAlarmStatus() async {
    if (throwOnFirstExactQuery) {
      throwOnFirstExactQuery = false;
      throw StateError('exact alarm query unavailable');
    }
    return exactAlarmStatusValue;
  }

  @override
  Future<PermissionStatus> requestExactAlarm() async {
    requestExactAlarmCalls++;
    exactAlarmStatusValue = PermissionStatus.granted;
    return exactAlarmStatusValue;
  }

  @override
  Future<PermissionStatus> batteryOptimizationStatus() async =>
      batteryStatusValue;

  @override
  Future<PermissionStatus> requestBatteryOptimizationExemption() async {
    requestBatteryCalls++;
    batteryStatusValue = PermissionStatus.granted;
    return batteryStatusValue;
  }

  @override
  Future<void> ensureNotificationInfrastructure() async {}

  @override
  Future<int> androidSdkInt() async => 35;

  @override
  Future<List<AndroidNotificationChannel>?> notificationChannels() async =>
      <AndroidNotificationChannel>[
        AndroidNotificationChannel(
          proactiveCareNotificationChannelId,
          'Proactive Care',
          importance: channelImportance,
        ),
      ];

  @override
  Future<Object?> invokeSettingsMethod(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    settingsCalls.add(method);
    if (method == 'openAutoStartSettings') return 'manufacturerSettings';
    return true;
  }
}
