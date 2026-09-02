import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/backup_reminder_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/update_provider.dart';
import 'package:Cuplivo/core/providers/user_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/home/widgets/side_drawer.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

/// loaded=true 阻止 SideDrawer post-frame 回调里的 GroupChatProvider.load()
/// → ChatService.init()（真实文件系统 + SQLite）。首帧只渲染 UI。
class _PreLoadedGroupChatProvider extends GroupChatProvider {
  _PreLoadedGroupChatProvider({required super.chatService});

  @override
  bool get loaded => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<BackupReminderProvider> loadReminder(BusinessPreferences prefs) async {
    final provider = BackupReminderProvider(
      preferences: prefs,
      autoLoad: false,
    );
    await provider.load(startTimer: false);
    return provider;
  }

  Future<void> pumpDrawer(
    WidgetTester tester, {
    required BackupReminderProvider reminder,
  }) async {
    final prefs = BusinessPreferences.memoryForTests({});
    final chatService = ChatService();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<BusinessPreferences>.value(value: prefs),
          ChangeNotifierProvider<ChatService>.value(value: chatService),
          ChangeNotifierProvider<SettingsProvider>.value(
            value: SettingsProvider(preferences: prefs),
          ),
          ChangeNotifierProvider<AssistantProvider>.value(
            value: AssistantProvider(preferences: prefs),
          ),
          ChangeNotifierProvider<UserProvider>.value(
            value: UserProvider(preferences: prefs),
          ),
          ChangeNotifierProvider<UpdateProvider>.value(value: UpdateProvider()),
          ChangeNotifierProvider<BackupReminderProvider>.value(value: reminder),
          ChangeNotifierProvider<GroupChatProvider>.value(
            value: _PreLoadedGroupChatProvider(chatService: chatService),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SideDrawer(userName: 'User', assistantName: 'Assistant'),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('backup entry visible by default (always-on)', (tester) async {
    final reminder = await loadReminder(BusinessPreferences.memoryForTests({}));

    await pumpDrawer(tester, reminder: reminder);

    // settingsPageBackup 入口标题。
    expect(find.text('Backup'), findsOneWidget);
    // 未到期：无催办行，也无独立尾部时间文本（非 due 时相对时间随标题行）。
    expect(find.textContaining('Backup due'), findsNothing);
  });

  testWidgets('hidden when always-off and reminder disabled', (tester) async {
    final reminder = await loadReminder(BusinessPreferences.memoryForTests({}));
    await reminder.setEntryAlwaysVisible(false);

    await pumpDrawer(tester, reminder: reminder);

    expect(find.text('Backup'), findsNothing);
  });

  testWidgets('hidden when always-off but reminder not yet due', (
    tester,
  ) async {
    final reminder = await loadReminder(BusinessPreferences.memoryForTests({}));
    await reminder.saveSchedule(
      enabled: true,
      intervalDays: 7,
      reminderMinutesOfDay: 8 * 60 + 30,
      now: DateTime(2026, 5, 5, 9),
    );
    // 下次提醒在 2026-05-12 08:30，此刻尚未到期。
    reminder.evaluateDue(DateTime(2026, 5, 10, 9));
    await reminder.setEntryAlwaysVisible(false);

    await pumpDrawer(tester, reminder: reminder);

    expect(find.text('Backup'), findsNothing);
  });

  testWidgets('visible with a single relative-time line when due', (
    tester,
  ) async {
    final reminder = await loadReminder(BusinessPreferences.memoryForTests({}));
    await reminder.saveSchedule(
      enabled: true,
      intervalDays: 7,
      reminderMinutesOfDay: 8 * 60 + 30,
      now: DateTime(2026, 5, 5, 9),
    );
    reminder.evaluateDue(DateTime(2026, 5, 15, 9));
    await reminder.setEntryAlwaysVisible(false);

    await pumpDrawer(tester, reminder: reminder);

    expect(find.text('Backup'), findsOneWidget);
    // due → 第二行催办（relative label = "Never"）：只有这一行，
    // 且无重复的独立尾部时间文本（due 时尾部时间被移除）。
    expect(find.textContaining('Backup due'), findsOneWidget);
    expect(find.textContaining('Last backup Never'), findsOneWidget);
    expect(find.text('Never'), findsNothing);
  });
}
