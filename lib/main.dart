import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'dart:async';
import 'l10n/app_localizations.dart';
import 'features/home/pages/home_page.dart';
import 'desktop/desktop_home_page.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'desktop/desktop_window_controller.dart';
import 'desktop/desktop_tray_controller.dart';
import 'desktop/windows_paste_fix.dart';
// import 'package:logging/logging.dart' as logging;
// Theme is now managed in SettingsProvider
import 'theme/theme_factory.dart';
import 'theme/palettes.dart';
import 'theme/custom_theme.dart';
import 'package:provider/provider.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'core/providers/chat_provider.dart';
import 'core/providers/user_provider.dart';
import 'core/providers/settings_provider.dart';
import 'core/providers/codex_device_code_controller.dart';
import 'core/providers/grok_device_code_controller.dart';
import 'core/providers/mcp_provider.dart';
import 'core/providers/workspace_provider.dart';
import 'core/services/saf/saf_mount_sync_service.dart';
import 'core/services/workspace/linux_sandbox_service.dart';
import 'core/services/workspace/workspace_terminal_coordinator.dart';
import 'core/services/workspace/workspace_terminal_native_bridge.dart';
import 'features/workspace/controllers/dependency_install_controller.dart';
import 'core/providers/tts_provider.dart';
import 'core/providers/asr_provider.dart';
import 'core/providers/assistant_provider.dart';
import 'core/providers/group_chat_provider.dart';
import 'core/providers/tag_provider.dart';
import 'core/providers/update_provider.dart';
import 'core/providers/quick_phrase_provider.dart';
import 'core/providers/instruction_injection_provider.dart';
import 'core/providers/instruction_injection_group_provider.dart';
import 'core/providers/world_book_provider.dart';
import 'core/providers/memory_provider.dart';
import 'core/providers/backup_provider.dart';
import 'core/providers/s3_backup_provider.dart';
import 'core/providers/backup_reminder_provider.dart';
import 'core/providers/hotkey_provider.dart';
import 'core/providers/download_progress_store.dart';
import 'core/providers/input_status_provider.dart';
import 'core/services/chat/chat_service.dart';
import 'core/services/trash_restore_coordinator.dart';
import 'core/services/mcp/mcp_tool_service.dart';
import 'core/services/generation_engine.dart';
import 'core/services/wake_lock_manager.dart';
import 'core/services/network/dio_http_client.dart';
import 'core/services/logging/flutter_logger.dart';
import 'features/home/services/ask_user_interaction_service.dart';
import 'features/home/services/input_draft_persistence.dart';
import 'features/home/services/tool_approval_service.dart';
import 'utils/sandbox_path_resolver.dart';
import 'features/skills/skill_manager.dart';
import 'shared/widgets/app_overlays.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:system_fonts/system_fonts.dart';
import 'dart:io'
    show Platform; // kept for global override usage inside provider
import 'core/services/android_background.dart';
import 'core/services/android_display_mode.dart';
import 'core/services/notification_service.dart';
import 'core/services/proactive_care_alarm_service.dart';
import 'core/services/proactive_care_message_flow.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'core/database/business_preferences.dart';
import 'core/database/business_repository.dart';
import 'core/database/business_startup_gate.dart';
import 'core/database/business_migration_engine.dart';
import 'core/database/app_database.dart';

final RouteObserver<ModalRoute<dynamic>> routeObserver =
    RouteObserver<ModalRoute<dynamic>>();
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
bool _didCheckUpdates = false; // one-time update check flag
bool _didInitializeWorkspaceTerminal = false;

/// Builds an HTTP client for MCP OAuth discovery/registration/loopback
/// traffic, honoring the app's global proxy setting. The MCP transport
/// (SSE) is proxied elsewhere; without this the OAuth handshake would
/// bypass the proxy and fail on networks that require it.
http.Client _oauthHttpClient(SettingsProvider sp) {
  final enabled = sp.globalProxyEnabled;
  final host = sp.globalProxyHost.trim();
  final portStr = sp.globalProxyPort.trim();
  final user = sp.globalProxyUsername.trim();
  final pass = sp.globalProxyPassword;
  if (enabled && host.isNotEmpty && portStr.isNotEmpty) {
    final port = int.tryParse(portStr) ?? 8080;
    return DioHttpClient(
      proxy: NetworkProxyConfig(
        enabled: true,
        type: sp.globalProxyType,
        host: host,
        port: port,
        username: user.isEmpty ? null : user,
        password: pass.isEmpty ? null : pass,
      ),
    );
  }
  return DioHttpClient();
}

Future<void> main() async {
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Windows clipboard history (Win+V) sends malformed Ctrl+V key sequences.
      // Workaround Flutter engine bug flutter#143997 until upstream is fixed.
      WindowsPasteFix.instance.inject();

      FlutterLogger.installGlobalHandlers();
      // Android: request the highest refresh rate now and again on every
      // resume (fire-and-forget; failures never block startup).
      AndroidDisplayModeService.instance.install();
      try {
        final prefs = await SharedPreferences.getInstance();
        final enabled = prefs.getBool('flutter_log_enabled_v1') ?? false;
        await FlutterLogger.setEnabled(enabled);
      } catch (_) {}
      // Preload the chat input draft synchronously (before runApp) so restore
      // at input-bar mount is race-free: the user cannot type before the
      // draft is already in the controller.
      await InputDraftPersistence.ensureInitialized();
      // Business preferences: one-shot SharedPreferences → SQLite KV migration
      // BEFORE any provider reads (async gap: no consumer can observe an empty
      // business cache while legacy data still exists). Recoverable failures
      // degrade to defaults and retain the legacy data for a retry.
      late BusinessPreferences businessPreferences;
      try {
        businessPreferences = await BusinessStartupGate.migrateAndLoad(
          repository: BusinessRepository(await AppDatabase.openShared()),
          legacyPreferences:
              await SharedPreferencesLegacyBusinessPreferences.open(),
        );
      } catch (e, st) {
        debugPrint('[main] business preferences migration failed: $e\n$st');
        FlutterLogger.log(
          'Business preferences migration failed: $e\n$st',
          tag: 'Startup',
          force: true,
        );
        // No silent empty-state: fall back to a memory-backed facade so
        // settings stay usable this session; next launch retries migration.
        businessPreferences = await BusinessPreferences.memoryFallback();
      }
      DesktopWindowController.instance.preferences =
          businessPreferences; // Trim Flutter global image cache to reduce memory pressure from large images
      try {
        PaintingBinding.instance.imageCache.maximumSize = 200;
        PaintingBinding.instance.imageCache.maximumSizeBytes =
            48 << 20; // ~48MB
      } catch (_) {}
      // Desktop (Windows) window setup: hide native title bar for custom Flutter bar
      await _initDesktopWindow();
      // Avoid preloading all system fonts at launch (huge memory on desktop)
      // Debug logging and global error handlers were enabled previously for diagnosis.
      // They are commented out now per request to reduce log noise.
      // FlutterError.onError = (FlutterErrorDetails details) { ... };
      // WidgetsBinding.instance.platformDispatcher.onError = (Object error, StackTrace stack) { ... };
      // logging.Logger.root.level = logging.Level.ALL;
      // logging.Logger.root.onRecord.listen((rec) { ... });
      // Cache current Documents directory to fix sandboxed absolute paths on iOS
      await SandboxPathResolver.init();
      // Skills root is feature-level: a resolution failure (e.g. path_provider
      // channel unavailable) must not block app startup. Degrade to "skills
      // unavailable this session" instead of dying before runApp.
      try {
        await SkillManager.initRoot();
      } catch (e, st) {
        debugPrint('[main] SkillManager.initRoot failed: $e\n$st');
        FlutterLogger.log(
          'SkillManager.initRoot failed: $e\n$st',
          tag: 'Startup',
          force: true,
        );
      }
      await CodexDeviceCodeController.instance.init();
      await GrokDeviceCodeController.instance.init();
      // Enable edge-to-edge to allow content under system bars (Android)
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      // Android: start AlarmManager service for proactive care exact alarms
      if (!kIsWeb && Platform.isAndroid) {
        await ProactiveCareAlarmService.initialize();
      }
      // Start app (Flutter log capture is toggleable and off by default)
      runApp(MyApp(preferences: businessPreferences));
    },
    // Unhandled root-isolate errors must not kill the process silently: log
    // them (console + Flutter log file, forced regardless of the log toggle)
    // and keep the app alive.
    (Object error, StackTrace stack) {
      debugPrint('[main] uncaught error: $error\n$stack');
      FlutterLogger.log('$error\n$stack', tag: 'Uncaught', force: true);
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        FlutterLogger.logPrint(line);
        parent.print(zone, line);
      },
    ),
  );
}

Future<void> _initDesktopWindow() async {
  if (kIsWeb) return;
  try {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      await windowManager.ensureInitialized();
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    }
    // Initialize and show desktop window with persisted size/position
    await DesktopWindowController.instance.initializeAndShow(title: 'Cuplivo');
  } catch (_) {
    // Ignore on unsupported platforms.
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.preferences});

  final BusinessPreferences preferences;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<BusinessPreferences>.value(value: preferences),
        ChangeNotifierProvider(
          create: (_) => ChatProvider(preferences: preferences),
        ),
        ChangeNotifierProvider(
          create: (_) => UserProvider(preferences: preferences),
        ),
        ChangeNotifierProvider(
          create: (_) {
            final settings = SettingsProvider(preferences: preferences);
            unawaited(settings.incrementAppLaunchCount());
            return settings;
          },
        ),
        ChangeNotifierProvider<CodexDeviceCodeController>.value(
          value: CodexDeviceCodeController.instance,
        ),
        ChangeNotifierProvider<GrokDeviceCodeController>.value(
          value: GrokDeviceCodeController.instance,
        ),
        ChangeNotifierProvider(create: (_) => ChatService()),
        Provider<InputDraftPersistence>.value(
          value: InputDraftPersistence.instance,
        ),
        ChangeNotifierProvider(create: (_) => McpToolService()),
        ChangeNotifierProvider(
          create: (_) => WorkspaceProvider(preferences: preferences),
        ),
        ChangeNotifierProvider(
          create: (ctx) => SafMountSyncService(
            workspaces: ctx.read<WorkspaceProvider>(),
            preferences: preferences,
          ),
        ),
        Provider(
          create: (ctx) => WorkspaceTerminalCoordinator(
            workspaces: WorkspaceProviderTerminalStore(
              ctx.read<WorkspaceProvider>(),
            ),
            sandbox: WorkspaceTerminalSandboxGateway(
              sandbox: LinuxSandboxService.instance,
              safMounts: ctx.read<SafMountSyncService>(),
            ),
            terminal: WorkspaceTerminalNativeBridge.instance,
          ),
        ),
        ChangeNotifierProvider(create: (_) => DependencyInstallController()),
        ChangeNotifierProvider(
          create: (ctx) => AssistantProvider(
            preferences: preferences,
            chatService: ctx.read<ChatService>(),
            settings: ctx.read<SettingsProvider>(),
          ),
        ),
        ChangeNotifierProvider(
          create: (ctx) =>
              GroupChatProvider(chatService: ctx.read<ChatService>()),
        ),
        ChangeNotifierProvider(create: (_) => ToolApprovalService()),
        ChangeNotifierProvider(create: (_) => AskUserInteractionService()),
        ChangeNotifierProvider(create: (_) => DownloadProgressStore()),
        ChangeNotifierProvider(create: (_) => InputStatusProvider()),
        ChangeNotifierProvider(
          create: (ctx) {
            final settings = ctx.read<SettingsProvider>();
            return GenerationEngine(
              chatService: ctx.read<ChatService>(),
              downloadProgressStore: ctx.read<DownloadProgressStore>(),
              wakeLockManager: WakeLockManager(
                isEnabled: () => settings.keepScreenOnDuringGeneration,
              ),
            );
          },
        ),
        ChangeNotifierProvider(
          create: (ctx) {
            final sp = ctx.read<SettingsProvider>();
            return McpProvider(
              preferences: preferences,
              chatService: ctx.read<ChatService>(),
              contextProvider: () => navigatorKey.currentContext!,
              oauthClientFactory: () => _oauthHttpClient(sp),
            );
          },
        ),
        ChangeNotifierProvider(
          create: (_) => TagProvider(preferences: preferences),
        ),
        ChangeNotifierProvider(
          create: (_) => TtsProvider(preferences: preferences),
        ),
        ChangeNotifierProvider(
          create: (ctx) =>
              AsrProvider(settingsProvider: ctx.read<SettingsProvider>()),
        ),
        ChangeNotifierProvider(create: (_) => UpdateProvider()),
        ChangeNotifierProvider(
          create: (ctx) => QuickPhraseProvider(
            preferences: preferences,
            chatService: ctx.read<ChatService>(),
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => InstructionInjectionProvider(preferences: preferences),
        ),
        ChangeNotifierProvider(
          create: (_) =>
              InstructionInjectionGroupProvider(preferences: preferences),
        ),
        ChangeNotifierProvider(
          create: (ctx) => WorldBookProvider(
            preferences: preferences,
            chatService: ctx.read<ChatService>(),
          ),
        ),
        ChangeNotifierProvider(
          create: (ctx) => MemoryProvider(
            preferences: preferences,
            chatService: ctx.read<ChatService>(),
          ),
        ),
        Provider(
          create: (ctx) => TrashRestoreCoordinator(
            chatService: ctx.read<ChatService>(),
            preferences: preferences,
            assistantProvider: ctx.read<AssistantProvider>(),
            worldBookProvider: ctx.read<WorldBookProvider>(),
            quickPhraseProvider: ctx.read<QuickPhraseProvider>(),
            mcpProvider: ctx.read<McpProvider>(),
            memoryProvider: ctx.read<MemoryProvider>(),
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => BackupReminderProvider(preferences: preferences),
        ),
        // Desktop hotkeys provider
        ChangeNotifierProvider(create: (_) => HotkeyProvider()),
        ChangeNotifierProvider(
          create: (ctx) => BackupProvider(
            chatService: ctx.read<ChatService>(),
            trashRestoreCoordinator: ctx.read<TrashRestoreCoordinator>(),
            preferences: preferences,
            initialConfig: ctx.read<SettingsProvider>().webDavConfig,
          ),
        ),
        ChangeNotifierProvider(
          create: (ctx) => S3BackupProvider(
            chatService: ctx.read<ChatService>(),
            trashRestoreCoordinator: ctx.read<TrashRestoreCoordinator>(),
            preferences: preferences,
            initialConfig: ctx.read<SettingsProvider>().s3Config,
          ),
        ),
      ],
      child: Builder(
        builder: (context) {
          final settings = context.watch<SettingsProvider>();
          // Apply global proxy overrides when settings change
          settings.applyGlobalProxyOverridesIfNeeded();
          // Lazily ensure system fonts only if user selected a system family (desktop only)
          // Load ONLY selected families to avoid huge memory from loading all system fonts.
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            try {
              final isDesktop =
                  !kIsWeb &&
                  (defaultTargetPlatform == TargetPlatform.windows ||
                      defaultTargetPlatform == TargetPlatform.macOS ||
                      defaultTargetPlatform == TargetPlatform.linux);
              if (!isDesktop) return;
              // Selected system app/code fonts (not Google, not local alias)
              final wantsAppSystem =
                  (settings.appFontFamily?.isNotEmpty == true) &&
                  !settings.appFontIsGoogle &&
                  (settings.appFontLocalAlias == null ||
                      settings.appFontLocalAlias!.isEmpty);
              final wantsCodeSystem =
                  (settings.codeFontFamily?.isNotEmpty == true) &&
                  !settings.codeFontIsGoogle &&
                  (settings.codeFontLocalAlias == null ||
                      settings.codeFontLocalAlias!.isEmpty);
              if (wantsAppSystem || wantsCodeSystem) {
                final sf = SystemFonts();
                if (wantsAppSystem) {
                  final fam = settings.appFontFamily!;
                  try {
                    await sf.loadFont(fam);
                  } catch (_) {}
                }
                if (wantsCodeSystem) {
                  final fam = settings.codeFontFamily!;
                  try {
                    if (fam != settings.appFontFamily) await sf.loadFont(fam);
                  } catch (_) {}
                }
              }
            } catch (_) {}
          });
          // One-time app update check after first build
          if (settings.showAppUpdates && !_didCheckUpdates) {
            _didCheckUpdates = true;
            WidgetsBinding.instance.addPostFrameCallback((_) async {
              try {
                await settings.loaded;
                if (!context.mounted || !settings.showAppUpdates) return;
                await context.read<UpdateProvider>().checkForUpdates();
              } catch (_) {}
            });
          }
          return DynamicColorBuilder(
            builder: (lightDynamic, darkDynamic) {
              // if (lightDynamic != null) {
              //   debugPrint('[DynamicColor] Light dynamic detected. primary=${lightDynamic.primary.value.toRadixString(16)} surface=${lightDynamic.surface.value.toRadixString(16)}');
              // } else {
              //   debugPrint('[DynamicColor] Light dynamic not available');
              // }
              // if (darkDynamic != null) {
              //   debugPrint('[DynamicColor] Dark dynamic detected. primary=${darkDynamic.primary.value.toRadixString(16)} surface=${darkDynamic.surface.value.toRadixString(16)}');
              // } else {
              //   debugPrint('[DynamicColor] Dark dynamic not available');
              // }
              final isAndroid =
                  Theme.of(context).platform == TargetPlatform.android;
              // Update dynamic color capability for settings UI (avoid notify during build)
              final dynSupported =
                  isAndroid && (lightDynamic != null || darkDynamic != null);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                try {
                  settings.setDynamicColorSupported(dynSupported);
                } catch (_) {}
              });

              // Initialize desktop hotkeys on supported platforms
              WidgetsBinding.instance.addPostFrameCallback((_) async {
                try {
                  final isDesktop =
                      !kIsWeb &&
                      (defaultTargetPlatform == TargetPlatform.windows ||
                          defaultTargetPlatform == TargetPlatform.macOS ||
                          defaultTargetPlatform == TargetPlatform.linux);
                  if (isDesktop) {
                    await context.read<HotkeyProvider>().initialize();
                  }
                } catch (_) {}
              });

              // Android-only: ensure background execution matches setting and prepare notifications if needed
              WidgetsBinding.instance.addPostFrameCallback((_) async {
                try {
                  if (Platform.isAndroid) {
                    final mode = settings.androidBackgroundChatMode;
                    final l10n = AppLocalizations.of(context);
                    if (l10n == null) return;
                    if (mode != AndroidBackgroundChatMode.off) {
                      // Enable only if currently disabled to avoid duplicate ROM prompts
                      try {
                        final already =
                            await AndroidBackgroundManager.isEnabled();
                        if (!already) {
                          await AndroidBackgroundManager.ensureInitialized(
                            notificationTitle:
                                l10n.androidBackgroundNotificationTitle,
                            notificationText:
                                l10n.androidBackgroundNotificationText,
                          );
                          await AndroidBackgroundManager.setEnabled(true);
                        }
                      } catch (_) {}
                      if (mode == AndroidBackgroundChatMode.onNotify) {
                        await NotificationService.ensureInitialized();
                        await NotificationService.ensureAndroidNotificationsPermission();
                      }
                    }
                    // Persist l10n strings so the background isolate can use
                    // localized text instead of English fallbacks. Alarm
                    // recovery (rescheduleAll) runs in HomePageController
                    // initChat after assistants finish loading — the
                    // assistant list is not available at first frame, see
                    // docs/adr/0031-proactive-care-startup-reschedule-and-logging.md.
                    try {
                      if (ProactiveCareAlarmService.isSupported) {
                        await ProactiveCareMessageFlow(
                          preferences: preferences,
                        ).saveL10nSnapshot(
                          defaultConversationTitle:
                              l10n.chatServiceDefaultConversationTitle,
                          carePromptDefault:
                              l10n.assistantEditProactiveCarePromptDefault,
                          decisionPromptDefault: l10n
                              .assistantEditProactiveCareDecisionPromptDefault,
                          failureNotificationBody:
                              l10n.proactiveCareFailedNotificationBody,
                        );
                      }
                    } catch (e) {
                      debugPrint(
                        '[ProactiveCare] L10n snapshot save failed: $e',
                      );
                    }
                  }
                } catch (e) {
                  debugPrint('[main] Android background setup failed: $e');
                }
              });

              final useDyn = isAndroid && settings.useDynamicColor;
              final custom = settings.selectedCustomTheme;
              final isCustomPalette =
                  settings.themePaletteId == ThemePalettes.customPaletteId &&
                  custom != null;
              final palette = isCustomPalette
                  ? buildCustomThemePalette(custom)
                  : ThemePalettes.byId(settings.themePaletteId);

              ColorScheme? lightDynOverride;
              ColorScheme? darkDynOverride;
              if (isCustomPalette) {
                // Custom theme wins over Android system dynamic color
                // (ADR-0038) — the custom palette is used as-is.
                lightDynOverride = null;
                darkDynOverride = null;
              } else if (useDyn) {
                lightDynOverride = lightDynamic;
                darkDynOverride = darkDynamic;
              }

              final light = buildLightThemeForScheme(
                palette.light,
                dynamicScheme: lightDynOverride,
                pureBackground: settings.usePureBackground,
              );
              final dark = buildDarkThemeForScheme(
                palette.dark,
                dynamicScheme: darkDynOverride,
                pureBackground: settings.usePureBackground,
              );
              // Resolve effective app font family (system/Google/local alias)
              String? effectiveAppFontFamily() {
                final fam = settings.appFontFamily;
                if (fam == null || fam.isEmpty) return null;
                if (settings.appFontIsGoogle) {
                  try {
                    final s = GoogleFonts.getFont(fam);
                    return s.fontFamily ?? fam;
                  } catch (_) {
                    return fam;
                  }
                }
                return fam;
              }

              final effectiveAppFont = effectiveAppFontFamily();

              // Apply user-selected app font to theme text styles and app bar
              ThemeData applyAppFont(ThemeData base) {
                if (effectiveAppFont == null || effectiveAppFont.isEmpty) {
                  return base;
                }
                TextStyle? withFamily(TextStyle? s) =>
                    s?.copyWith(fontFamily: effectiveAppFont);
                TextTheme apply(TextTheme t) => t.copyWith(
                  displayLarge: withFamily(t.displayLarge),
                  displayMedium: withFamily(t.displayMedium),
                  displaySmall: withFamily(t.displaySmall),
                  headlineLarge: withFamily(t.headlineLarge),
                  headlineMedium: withFamily(t.headlineMedium),
                  headlineSmall: withFamily(t.headlineSmall),
                  titleLarge: withFamily(t.titleLarge),
                  titleMedium: withFamily(t.titleMedium),
                  titleSmall: withFamily(t.titleSmall),
                  bodyLarge: withFamily(t.bodyLarge),
                  bodyMedium: withFamily(t.bodyMedium),
                  bodySmall: withFamily(t.bodySmall),
                  labelLarge: withFamily(t.labelLarge),
                  labelMedium: withFamily(t.labelMedium),
                  labelSmall: withFamily(t.labelSmall),
                );
                final bar = base.appBarTheme;
                final appBar = bar.copyWith(
                  titleTextStyle: (bar.titleTextStyle ?? const TextStyle())
                      .copyWith(fontFamily: effectiveAppFont),
                  toolbarTextStyle: (bar.toolbarTextStyle ?? const TextStyle())
                      .copyWith(fontFamily: effectiveAppFont),
                );
                // Apply as default family to all text in ThemeData
                return base.copyWith(
                  textTheme: apply(base.textTheme),
                  primaryTextTheme: apply(base.primaryTextTheme),
                  appBarTheme: appBar,
                );
              }

              final themedLight = applyAppFont(light);
              final themedDark = applyAppFont(dark);
              // Log top-level colors likely used by widgets (card/bg/shadow approximations)
              // debugPrint('[Theme/App] Light scaffoldBg=${light.colorScheme.surface.value.toRadixString(16)} card≈${light.colorScheme.surface.value.toRadixString(16)} shadow=${light.colorScheme.shadow.value.toRadixString(16)}');
              // debugPrint('[Theme/App] Dark scaffoldBg=${dark.colorScheme.surface.value.toRadixString(16)} card≈${dark.colorScheme.surface.value.toRadixString(16)} shadow=${dark.colorScheme.shadow.value.toRadixString(16)}');
              return MaterialApp(
                navigatorKey: navigatorKey,
                debugShowCheckedModeBanner: false,
                title: 'Cuplivo',
                // App UI language; null = follow system (respects iOS per-app language)
                locale: settings.appLocaleForMaterialApp,
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                theme: themedLight,
                darkTheme: themedDark,
                themeMode: settings.themeMode,
                navigatorObservers: <NavigatorObserver>[routeObserver],
                home: _selectHome(),
                builder: (ctx, child) {
                  final bright = Theme.of(ctx).brightness;
                  final overlay = bright == Brightness.dark
                      ? const SystemUiOverlayStyle(
                          statusBarColor: Colors.transparent,
                          statusBarIconBrightness: Brightness.light,
                          statusBarBrightness: Brightness.dark,
                          systemNavigationBarColor: Colors.transparent,
                          systemNavigationBarIconBrightness: Brightness.light,
                          systemNavigationBarDividerColor: Colors.transparent,
                          systemNavigationBarContrastEnforced: false,
                        )
                      : const SystemUiOverlayStyle(
                          statusBarColor: Colors.transparent,
                          statusBarIconBrightness: Brightness.dark,
                          statusBarBrightness: Brightness.light,
                          systemNavigationBarColor: Colors.transparent,
                          systemNavigationBarIconBrightness: Brightness.dark,
                          systemNavigationBarDividerColor: Colors.transparent,
                          systemNavigationBarContrastEnforced: false,
                        );
                  // Ensure localized defaults after first frame
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    try {
                      ctx.read<ChatService>().setDefaultConversationTitle(
                        AppLocalizations.of(
                          ctx,
                        )!.chatServiceDefaultConversationTitle,
                      );
                    } catch (_) {}
                    try {
                      ctx.read<UserProvider>().setDefaultNameIfUnset(
                        AppLocalizations.of(ctx)!.userProviderDefaultUserName,
                      );
                    } catch (_) {}
                  });

                  // Desktop tray + close behaviour (minimize to tray) sync
                  final l10n = AppLocalizations.of(ctx);
                  if (l10n != null &&
                      Platform.isAndroid &&
                      !_didInitializeWorkspaceTerminal) {
                    _didInitializeWorkspaceTerminal = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) async {
                      try {
                        await ctx
                            .read<WorkspaceTerminalCoordinator>()
                            .initialize(
                              WorkspaceTerminalNotificationStrings(
                                channelName:
                                    l10n.workspaceTerminalNotificationChannel,
                                title: l10n.workspaceTerminalNotificationTitle,
                                text: l10n.workspaceTerminalNotificationText,
                              ),
                            );
                      } catch (error, stackTrace) {
                        _didInitializeWorkspaceTerminal = false;
                        debugPrint(
                          '[WorkspaceTerminal] startup failed: '
                          '$error\n$stackTrace',
                        );
                      }
                    });
                  }
                  if (l10n != null) {
                    WidgetsBinding.instance.addPostFrameCallback((_) async {
                      try {
                        final isDesktop =
                            !kIsWeb &&
                            (defaultTargetPlatform == TargetPlatform.windows ||
                                defaultTargetPlatform == TargetPlatform.macOS ||
                                defaultTargetPlatform == TargetPlatform.linux);
                        if (!isDesktop) return;
                        final sp = ctx.read<SettingsProvider>();
                        await DesktopTrayController.instance.syncFromSettings(
                          l10n,
                          showTray: sp.desktopShowTray,
                          minimizeToTrayOnClose:
                              sp.desktopMinimizeToTrayOnClose,
                        );
                      } catch (_) {}
                    });
                  }

                  final mq = MediaQuery.of(ctx);
                  final display = View.of(ctx).display;
                  final displaySize = display.size / display.devicePixelRatio;
                  final isFloatingIpad =
                      defaultTargetPlatform == TargetPlatform.iOS &&
                      displaySize.shortestSide >= 600 &&
                      (mq.size.shortestSide < displaySize.shortestSide - 1 ||
                          mq.size.longestSide < displaySize.longestSide - 1);
                  final systemTop = mq.viewPadding.top;
                  final controlsTop = systemTop < 56 ? 56.0 : systemTop;
                  final appWithOverlays = MediaQuery(
                    data: isFloatingIpad
                        ? mq.copyWith(
                            padding: mq.padding.copyWith(top: controlsTop),
                            viewPadding: mq.viewPadding.copyWith(
                              top: controlsTop,
                            ),
                          )
                        : mq,
                    child: AppOverlays(child: child ?? const SizedBox.shrink()),
                  );
                  // Enforce app font as a default across the tree for Texts without explicit family
                  return AnnotatedRegion<SystemUiOverlayStyle>(
                    value: overlay,
                    child: effectiveAppFont == null
                        ? appWithOverlays
                        : DefaultTextStyle.merge(
                            style: TextStyle(fontFamily: effectiveAppFont),
                            child: appWithOverlays,
                          ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

Widget _selectHome() {
  // Mobile remains the default platform. Desktop is an added platform.
  if (kIsWeb) return const HomePage();
  final isDesktop =
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
  return isDesktop ? const DesktopHomePage() : const HomePage();
}

// Overrides logic is implemented within SettingsProvider now.
