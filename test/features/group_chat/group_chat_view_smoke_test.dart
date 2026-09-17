import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/user_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/group_chat/pages/group_chat_page.dart';
import 'package:Cuplivo/utils/sandbox_path_resolver.dart';
import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/l10n/app_localizations.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

// Deep-mount smoke of the full GroupChatView (real message list + input bar)
// needs the production provider graph (TTS, ASR, MCP, tool approval...);
// no whole-app test harness exists yet. The view is compose-only — the
// orchestrator/provider/repository layers carry the behavioral tests.
// Deferred to the release-regression pass.
void main() {
  late Directory tempDir;
  late AppDatabase database;
  late ChatService chatService;
  late BusinessPreferences preferences;
  late GroupChatProvider groupChatProvider;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('kelivo_gcv_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SandboxPathResolver.debugSetDirs(
      docsDir: tempDir.path,
      supportDir: tempDir.path,
    );
    SharedPreferences.setMockInitialValues({});
    database = AppDatabase(NativeDatabase.memory());
    chatService = ChatService(
      existingRepository: ChatDatabaseRepository(database),
    );
    await chatService.init();
    preferences = BusinessPreferences(BusinessRepository(database));
    groupChatProvider = GroupChatProvider(chatService: chatService);
    await groupChatProvider.load();
  });

  tearDown(() async {
    await chatService.close();
    await database.close();
    SandboxPathResolver.debugSetDirs(docsDir: null, supportDir: null);
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Widget harness(Widget child) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<GroupChatProvider>.value(
          value: groupChatProvider,
        ),
        ChangeNotifierProvider(create: (_) => SettingsProvider(preferences)),
        ChangeNotifierProvider(
          create: (_) => UserProvider(preferences: preferences),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    );
  }

  testWidgets('missing group renders the not-found fallback', (tester) async {
    await tester.pumpWidget(harness(const GroupChatPage(groupChatId: 'nope')));
    await tester.pump();
    expect(find.text('Group chat not found'), findsOneWidget);
  });
}
