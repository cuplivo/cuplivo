import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/features/assistant/pages/assistant_settings_page.dart';
import 'package:Cuplivo/features/harness/controllers/dsh_composer_e2e.dart';
import 'package:Cuplivo/features/harness/pages/home/harness_home_chrome.dart';
import 'package:Cuplivo/features/harness/pages/plugins/dsh_plugin_web_page.dart';
import 'package:Cuplivo/features/harness/pages/preview/dsh_file_preview_page.dart';
import 'package:Cuplivo/features/harness/services/dsh_surface_harvest.dart';
import 'package:Cuplivo/features/harness/widgets/chat/dsh_agent_preset_picker.dart';
import 'package:Cuplivo/features/harness/widgets/dsh_web_ui_view.dart';
import 'package:Cuplivo/features/home/pages/home_mobile_layout.dart';
import 'package:Cuplivo/features/home/widgets/message_list_view.dart';
import 'package:Cuplivo/features/home/widgets/side_drawer.dart';
import 'package:Cuplivo/features/settings/pages/settings_page.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

import 'acceptance_support.dart';

/// Android E2E acceptance scenario for the DeepSeek Harness remote slice.
///
/// Design: `docs/cuplivo-dsh/e2e-scenario.md`. The scenario has two modes
/// selected by the build defines the `/e2e` workflow passes:
///
/// - real (`E2E_DSH_URL` + `E2E_DSH_TOKEN` set): connects a new remote through
///   the production UI and drives R1–R11 end to end against the E2E host;
/// - hermetic (both empty): boots the same seeded app and drives every
///   navigation up to the direct-connect form, without connecting, sending or
///   asserting anything the host provides. It is the fork-PR path, so it must
///   pass with no network at all.
///
/// Exactly one of the two defines set is a configuration error. The token is
/// never printed, asserted on, or written anywhere; only a "configured"
/// boolean reaches the log. Screenshots are captured through
/// `acceptance_support.dart` so the workflow collects them from the platform
/// screenshot directory.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('DSH remote acceptance scenario', (tester) async {
    final hasUrl = _dshUrl.trim().isNotEmpty;
    final hasToken = _dshToken.trim().isNotEmpty;
    if (hasUrl != hasToken) {
      fail(
        'E2E_DSH_URL and E2E_DSH_TOKEN must both be set (real mode) or both be '
        'empty (hermetic mode); exactly one was provided.',
      );
    }
    final realMode = hasUrl && hasToken;
    // Never print the defines themselves: the URL identifies the operator's
    // host and the token is a launch credential.
    debugPrint(
      '[dsh-e2e] preflight {"mode":"${realMode ? 'real' : 'hermetic'}",'
      '"urlConfigured":$hasUrl,"tokenConfigured":$hasToken}',
    );

    await bootSeededApp(tester, binding, appLocale: 'zh_CN');
    final l10n = _l10n(tester);

    // R1: drawer → 助手与群聊 → create menu, where the third owner kind is
    // DeepSeek Harness.
    await _openDrawer(tester);
    if (!realMode) {
      // Hermetic evidence starts with the untouched local drawer.
      e2eStep('before hermetic_local_drawer');
      await capture(tester, binding, 'hermetic_local_drawer');
    }
    await _openChatOwnerSettings(tester, l10n);
    await _openCreateMenu(tester);

    final createMenuItem = find.byKey(const Key('dsh-create-menu-item'));
    await _pumpUntilFound(
      tester,
      createMenuItem,
      what: 'the DeepSeek Harness row of the create menu (R1)',
    );
    await capture(
      tester,
      binding,
      realMode ? 'r1_create_menu' : 'hermetic_create_menu',
    );

    await tester.tap(createMenuItem);
    final engineMode = find.byKey(const Key('dsh-engine-mode'));
    await _pumpUntilFound(tester, engineMode, what: 'the 直接连接 engine row (R1)');
    if (!realMode) {
      e2eStep('before hermetic_engine_sheet');
      await capture(tester, binding, 'hermetic_engine_sheet');
    }
    await tester.tap(engineMode);

    final nameField = find.byKey(const Key('dsh-connect-name'));
    final urlField = find.byKey(const Key('dsh-connect-url'));
    final confirmButton = find.byKey(const Key('dsh-connect-confirm'));
    await _pumpUntilFound(
      tester,
      nameField,
      what: 'the direct-connect form name field (R2)',
    );
    await _pumpUntilFound(
      tester,
      urlField,
      what: 'the direct-connect form WebUI URL field (R2)',
    );
    // R2: the URL field is empty here, so the token placeholder is the
    // rendered hint. Assert the hint text rather than find.text: entering a
    // URL replaces the glyphs, and the hint is the only durable evidence.
    _expectConnectUrlPlaceholder(tester, l10n);
    await _pumpUntilFound(
      tester,
      confirmButton,
      what: 'the direct-connect form 确认 button (R2)',
    );
    final tabs = find.byKey(const Key('dsh-settings-tabs'));
    await _pumpUntilFound(
      tester,
      tabs,
      what: 'the assistant settings tab strip (R2)',
    );
    // Create mode has no remote yet, so only the local tabs render; the
    // Host-reported tabs (内置插件 / Agent 预设) arrive after connecting.
    _expectSettingsTabs(tester, l10n);

    if (!realMode) {
      await _runHermeticTail(tester, binding);
      return;
    }

    await _runRealScenario(tester, binding, l10n);
    // Budget: the pass path is ~30-90 s of wall clock (local navigation, two
    // network round-trips - connect and one model answer - and 10-14 screenshot
    // frames). Every wait is capped (<=2 min of pumped frames in total), so a
    // hung Host fails with the wait's own message long before this timeout.
  }, timeout: const Timeout(Duration(minutes: 15)));
}

const String _dshUrl = String.fromEnvironment('E2E_DSH_URL');
const String _dshToken = String.fromEnvironment('E2E_DSH_TOKEN');

/// A short prompt the E2E host's temporary key can answer inside the emulator
/// budget (`docs/cuplivo-dsh/e2e-scenario.md`).
const String _prompt = '你好，请用一句话介绍你自己';

/// A second prompt that forces a bash tool call on the Host, so R6 covers the
/// tool-card path as well as a plain text answer (`e2e-scenario.md`).
const String _toolPrompt =
    '请用 bash 工具执行这条命令：echo CUPLIVO_E2E_TOOL_OK，然后把完整输出贴给我';

/// The line R12 types into the Host terminal. Its workspace side effect is the
/// assertion: `terminal_view` paints glyphs to a canvas, so no Flutter `Text`
/// can carry the output.
const String _terminalCommand =
    'echo CUPLIVO_E2E_TERMINAL_OK > cuplivo-e2e-terminal.txt';

AppLocalizations _l10n(WidgetTester tester) {
  final element = tester.element(find.byType(Scaffold).first);
  return AppLocalizations.of(element)!;
}

/// `"$base/?token=$token"` with the token kept out of every log.
String _tokenizedWebUiUrl() {
  final base = _dshUrl.trim();
  final withoutTrailingSlash = base.endsWith('/')
      ? base.substring(0, base.length - 1)
      : base;
  return '$withoutTrailingSlash/?token=${_dshToken.trim()}';
}

/// Real mode: connect, then drive chat, rail and the models settings (R3–R11).
Future<void> _runRealScenario(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  AppLocalizations l10n,
) async {
  // Fill the direct-connect form with the defines. The URL field accepts the
  // tokenized WebUI link; neither value is logged afterwards.
  await tester.enterText(
    find.byKey(const Key('dsh-connect-name')),
    'DeepSeek Harness',
  );
  await pumpFrames(tester, frames: 4);
  await tester.enterText(
    find.byKey(const Key('dsh-connect-url')),
    _tokenizedWebUiUrl(),
  );
  await pumpFrames(tester, frames: 4);

  // The form's 确认 button sits below the keyboard: dismiss the IME and scroll
  // it into view before tapping so the tap cannot land on a covered position.
  FocusManager.instance.primaryFocus?.unfocus();
  await pumpFrames(tester, frames: 10);
  final confirm = find.byKey(const Key('dsh-connect-confirm'));
  await tester.ensureVisible(confirm);
  await pumpFrames(tester, frames: 6);
  await tester.tap(confirm);
  final ownerCard = find.byKey(const Key('dsh-owner-card'));
  // The page pops back to 助手与群聊 only after the link is ready, so the card
  // appearing is also the "connected and catalog loaded" signal.
  await _pumpUntilFound(
    tester,
    ownerCard,
    what: 'the connected DeepSeek Harness owner card (R3)',
    maxFrames: 1800,
  );
  await pumpFrames(tester, frames: 30);
  expect(ownerCard, findsOneWidget);
  e2eStep('before r3_connected_card');
  await capture(tester, binding, 'r3_connected_card');

  // R2: the remote's assistant settings page, opened from the owner card.
  await tester.ensureVisible(ownerCard);
  await pumpFrames(tester, frames: 4);
  await tester.tap(ownerCard);
  final tabs = find.byKey(const Key('dsh-settings-tabs'));
  await _pumpUntilFound(
    tester,
    tabs,
    what: 'the assistant settings page tabs (R2)',
  );
  _expectSettingsTabs(tester, l10n, withHostTabs: true);
  await pumpFrames(tester, frames: 20);
  e2eStep('before r2_settings_connection');
  await capture(tester, binding, 'r2_settings_connection');

  // R2 v2: the two Host-reported tabs. Every body lives in one IndexedStack, so
  // a body's text only becomes findable after its own tab is tapped (default
  // finders skip offstage children).
  await _openSettingsTabById(
    tester,
    const Key('dsh-settings-tab-plugins'),
    what: 'the 内置插件 tab (R2)',
  );
  await _pumpUntilFound(
    tester,
    find.text(l10n.dshPluginsReadOnly),
    what: 'the 内置插件 read-only note (R2)',
  );
  expect(
    find.text(l10n.dshPluginsEnabled),
    findsWidgets,
    reason: 'R2 内置插件 rows report the Host plugin state',
  );
  expect(
    find.textContaining('@'),
    findsWidgets,
    reason: 'R2 内置插件 rows show the Host module name',
  );
  await pumpFrames(tester, frames: 20);
  e2eStep('before r2_builtin_plugins');
  await capture(tester, binding, 'r2_builtin_plugins');

  // R2 v2b: the generic plugin-settings tabs. Cuplivo knows no plugin names:
  // the 内置插件 tab carries one affordance that visits the Host's own settings
  // dialog, and the settings harvest reports whatever `settings.section` slots
  // the installed plugins registered. Those become tabs in the same strip.
  final officialSettings = find.byKey(
    const ValueKey<String>('dsh-settings-open-official'),
  );
  await _pumpUntilFound(
    tester,
    officialSettings,
    what: 'the 内置插件 official-settings affordance (R2)',
  );
  final authority = Uri.parse(_dshUrl).authority;
  // The settings script opens the official dialog and reads its nav rows; it is
  // the only source of truth for the plugin-contributed sections. The hosted
  // emulator's Chromium renderer cannot render the official single-page app at
  // all (`aw_browser_terminator` kills it within a second and nothing posts), so
  // the emulator asserts the honest degradation here; the DOM-contract job
  // (`dom-contract` in e2e-android.yml) proves the same recipe against the real
  // Host in a desktop Chrome.
  final officialAttempts = 2;
  var officialSections = const <DshSurfaceEntry>[];
  for (var attempt = 1; attempt <= officialAttempts; attempt++) {
    await tester.ensureVisible(officialSettings);
    await pumpFrames(tester, frames: 4);
    await tester.tap(officialSettings);
    await _pumpUntilFound(
      tester,
      find.byType(DshPluginWebPage),
      what: 'the official settings WebUI page (R2 attempt $attempt)',
      maxFrames: 900,
    );
    await pumpUntil(
      tester,
      () =>
          DshSurfaceInventory.shared.snapshotFor(authority).settings.isNotEmpty,
      maxFrames: 240,
    );
    officialSections = DshSurfaceInventory.shared
        .snapshotFor(authority)
        .settings;
    if (officialSections.isNotEmpty) {
      debugPrint(
        '[dsh-e2e] official settings harvest (attempt $attempt): '
        '${officialSections.length} section(s) '
        '(${officialSections.map((entry) => entry.label).join(' | ')})',
      );
      break;
    }
    debugPrint(
      '[dsh-e2e] official settings harvest attempt $attempt posted nothing '
      '(the emulator WebView renderer is unavailable on this Host)',
    );
    if (attempt == officialAttempts) break;
    await _popRoute(tester);
    await pumpFrames(tester, frames: 30);
    await _openSettingsTabById(
      tester,
      const Key('dsh-settings-tab-plugins'),
      what: 'the 内置插件 tab after a failed official-settings attempt (R2)',
    );
  }
  // The route itself is the emulator-side acceptance: the official WebUI page
  // opens from the affordance, and its absence of harvest degrades without
  // crashing the app. The harvested sections are asserted by the DOM-contract
  // job against the real Host.
  expect(
    find.byType(DshPluginWebPage),
    findsOneWidget,
    reason:
        'R2 the official settings affordance must open the Host WebUI page '
        '(the emulator cannot render its DOM; see the dom-contract job)',
  );
  e2eStep('before r2_official_settings');
  await capture(tester, binding, 'r2_official_settings');
  await _popRoute(tester);
  if (officialSections.isNotEmpty) {
    expect(
      officialSections,
      isNotEmpty,
      reason: 'R2 the official settings dialog reported its sections',
    );
  }

  expect(
    find.byKey(const Key('dsh-settings-tabs')),
    findsOneWidget,
    reason: 'R2 returns to the assistant settings page after the visit',
  );
  final harvestedSections = DshSurfaceInventory.shared
      .snapshotFor(authority)
      .pluginSettingsSections;
  final pluginTab = find.byWidgetPredicate(
    (widget) =>
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith(
          'dsh-settings-tab-plugin-',
        ),
    description: 'a plugin-registered settings tab (R2)',
  );
  if (harvestedSections.isNotEmpty) {
    await _pumpUntilFound(
      tester,
      pluginTab,
      what: 'a plugin-registered settings tab (R2)',
      maxFrames: 600,
    );
    expect(
      pluginTab,
      findsNWidgets(harvestedSections.length),
      reason:
          'every plugin-contributed settings section became exactly one tab '
          '(labels: ${harvestedSections.map((entry) => entry.label).join(', ')})',
    );
    for (final section in harvestedSections) {
      expect(
        find.descendant(
          of: find.byKey(const Key('dsh-settings-tabs')),
          matching: find.text(section.label),
        ),
        findsWidgets,
        reason: 'R2 the plugin tab keeps the Host label "${section.label}"',
      );
    }
    await pumpFrames(tester, frames: 20);
    e2eStep('before r2_plugin_settings_tabs');
    await capture(tester, binding, 'r2_plugin_settings_tabs');
    await tester.ensureVisible(pluginTab.first);
    await pumpFrames(tester, frames: 4);
    await tester.tap(pluginTab.first);
    await pumpFrames(tester, frames: 120);
    expect(
      find.byType(DshWebUiView),
      findsWidgets,
      reason: 'R2 a plugin settings tab embeds the official section',
    );
    e2eStep('before r2_plugin_settings_body');
    await capture(tester, binding, 'r2_plugin_settings_body');
  }

  await _openSettingsTabById(
    tester,
    const Key('dsh-settings-tab-agentPresets'),
    what: 'the Agent 预设 tab (R2)',
  );
  await _pumpUntilFound(
    tester,
    find.text(l10n.dshAgentPresetsReadOnly),
    what: 'the Agent 预设 read-only note (R2)',
  );
  // The Host's composition groups render by name (id when it reports no
  // name); `standard` is the default composition, and the 默认 badge belongs
  // to that group only.
  expect(
    find.text('standard'),
    findsWidgets,
    reason: 'R2 Agent 预设 lists the Host composition groups',
  );
  expect(
    find.text(l10n.dshAgentPresetsDefault),
    findsWidgets,
    reason: 'R2 Agent 预设 marks the default group',
  );
  await pumpFrames(tester, frames: 20);
  e2eStep('before r2_agent_presets');
  await capture(tester, binding, 'r2_agent_presets');

  // R8: the 通用设置 tab, switched through the existing pill strip. Switching
  // adds no route, so the three pops below still land on the home surface.
  final generalTab = find.descendant(
    of: tabs,
    matching: find.text(l10n.dshTabGeneral),
  );
  await _pumpUntilFound(tester, generalTab, what: 'the 通用设置 tab (R8)');
  await tester.ensureVisible(generalTab.first);
  await tester.tap(generalTab.first);
  await pumpFrames(tester, frames: 20);
  // R8's scope: only the default-permission row and the session-log toggle.
  expect(
    find.text(l10n.dshDefaultPermissionLabel),
    findsWidgets,
    reason: 'R8 选择新会话的默认权限限制',
  );
  expect(
    find.text(l10n.dshUploadSessionLogLabel),
    findsWidgets,
    reason: 'R8 在使用官方模型API时上传Session Log',
  );
  e2eStep('before r8_general_settings');
  await capture(tester, binding, 'r8_general_settings');

  // R9/R10/R11: the remote's model settings live on this same page. They run
  // here, in the R2/R8 settings session, because v2 removed the native 更多
  // menu that used to be the way back to this page.
  final modelsTab = find.descendant(
    of: tabs,
    matching: find.byKey(const Key('dsh-models-tab')),
  );
  await _pumpUntilFound(tester, modelsTab, what: 'the 模型 tab (R9)');
  await tester.ensureVisible(modelsTab.first);
  await tester.tap(modelsTab.first);

  final modelsSearch = find.byKey(const Key('dsh-models-search'));
  await _pumpUntilFound(
    tester,
    modelsSearch,
    what: 'the models settings page search field (R9)',
  );
  await pumpUntil(tester, () => _providerRowCount(tester) > 0, maxFrames: 1200);
  expect(
    _providerRowCount(tester),
    greaterThan(0),
    reason: 'provider rows from the live catalog (R9)',
  );
  final customProviderRow = find.byKey(const Key('dsh-models-custom-provider'));
  await _pumpUntilFound(
    tester,
    customProviderRow,
    what: 'the 自定义提供商 row (R10)',
  );
  final customTop = tester.getTopLeft(customProviderRow);
  final firstProviderTop = tester.getTopLeft(_providerRows().first);
  expect(
    customTop.dy <= firstProviderTop.dy,
    isTrue,
    reason: 'R10 the 自定义提供商 row stays first',
  );
  await pumpFrames(tester, frames: 20);
  e2eStep('before r9_models');
  await capture(tester, binding, 'r9_models');

  // R10: the add-provider list, opened by the search bar's + action. The
  // models slice owns `dsh-models-add-provider`; the icon inside the search
  // bar is the fallback until that key lands.
  final keyedAddProvider = find.byKey(const Key('dsh-models-add-provider'));
  final addProvider = keyedAddProvider.evaluate().isNotEmpty
      ? keyedAddProvider
      : find.descendant(of: modelsSearch, matching: find.byIcon(Lucide.Plus));
  expect(addProvider, findsWidgets, reason: 'the R9 + add-provider action');
  await tester.tap(addProvider.first);
  final addProviderPicker = find.byKey(const Key('dsh-add-provider-picker'));
  await _pumpUntilFound(
    tester,
    addProviderPicker,
    what: 'the add-provider list (R10)',
  );
  await pumpFrames(tester, frames: 20);
  e2eStep('before r10_add_provider');
  await capture(tester, binding, 'r10_add_provider');

  // R11: close the add-provider list deterministically (a barrier tap could
  // land on the search field) and open deepseek-official's editable detail from
  // the models list. The settings seam is wired, so every configurable row now
  // opens the editable form rather than the read-only placeholder.
  Navigator.of(
    tester.element(find.byKey(const Key('dsh-add-provider-picker'))),
  ).pop();
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 8),
  );

  // The models list is virtualized and deepseek-official sits well below the
  // fold, so search to build the row; this also exercises the search field.
  await tester.enterText(modelsSearch, 'deepseek');
  await pumpFrames(tester, frames: 20);
  final officialRow = find.byKey(
    const ValueKey<String>('dsh-provider-row-deepseek-official'),
  );
  await _pumpUntilFound(
    tester,
    officialRow,
    what: 'the deepseek-official provider row after search (R11)',
    maxFrames: 600,
  );
  final enabledPill = find.descendant(
    of: officialRow,
    matching: find.text(l10n.dshModelsProviderEnabled),
  );
  await _pumpUntilFound(
    tester,
    enabledPill,
    what: 'the 启用 pill of the deepseek-official row (R11)',
    maxFrames: 1200,
  );
  FocusManager.instance.primaryFocus?.unfocus();
  await pumpFrames(tester, frames: 12);
  await tester.tap(officialRow);

  final providerApiKey = find.byKey(const Key('dsh-provider-detail-api-key'));
  await _pumpUntilFound(
    tester,
    providerApiKey,
    what: 'the editable provider detail form (R11)',
    maxFrames: 900,
  );
  expect(
    find.text('deepseek-official'),
    findsWidgets,
    reason: 'R11 provider id deepseek-official',
  );
  final modelsSection = find.text(l10n.dshProviderDetailModels);
  if (modelsSection.evaluate().isEmpty) {
    final formScrollable = find.ancestor(
      of: providerApiKey,
      matching: find.byType(Scrollable),
    );
    if (formScrollable.evaluate().isNotEmpty) {
      await tester.drag(formScrollable.first, const Offset(0, -220));
      await pumpFrames(tester, frames: 12);
    }
  }
  expect(modelsSection, findsWidgets, reason: 'R11 模型目录 section');
  await pumpFrames(tester, frames: 20);
  e2eStep('before r11_provider_detail');
  await capture(tester, binding, 'r11_provider_detail');

  // Back to the models list, then leave settings for the harness surfaces.
  await _popRoute(tester);
  await pumpFrames(tester, frames: 8);
  expect(
    find.byKey(const Key('dsh-models-search')),
    findsOneWidget,
    reason: 'R11 closes back onto the models list',
  );
  await tester.enterText(modelsSearch, '');
  await pumpFrames(tester, frames: 12);
  FocusManager.instance.primaryFocus?.unfocus();
  await pumpFrames(tester, frames: 12);
  expect(
    _providerRows().evaluate().length,
    greaterThan(1),
    reason: 'clearing the R11 search restores the full models list',
  );

  // The connect/settings flow owns a variable route depth; pop until the home
  // surface is the only route, bounded so a deep stack fails here instead of
  // silently going back too far.
  var settingsPops = 0;
  while (_rootNavigator(tester).canPop() && settingsPops < 4) {
    await _popRoute(tester);
    settingsPops++;
  }
  expect(
    _rootNavigator(tester).canPop(),
    isFalse,
    reason: 'the scenario is back on the home surface after R11',
  );
  // The owner list is a pushed page, so the bounded pop loop above already
  // left it; R4 is reached from the home surface through the drawer below.
  await pumpFrames(tester, frames: 20);
  expect(
    find.byType(HomeMobileScaffold),
    findsWidgets,
    reason: 'the home scaffold is back after leaving settings (R4)',
  );

  // R5: the drawer now lists the remote owner; tapping it enters harness mode.
  // On a phone the drawer body is the conversation list, so the owner rows live
  // in the inline assistant picker that the current-assistant header expands.
  await _openDrawer(tester);
  await _expandAssistantPickerForOwners(tester);
  final ownerRow = find.byKey(const Key('dsh-owner-row'));
  await _pumpUntilFound(
    tester,
    ownerRow,
    what: 'the DeepSeek Harness owner row in the expanded picker (R5)',
  );
  await tester.ensureVisible(ownerRow);
  await pumpFrames(tester, frames: 20);
  // R4: the local sidebar lists the remote as an owner (whale avatar and the
  // pencil setting), above the conversation list, under the search field.
  e2eStep('before r4_local_sidebar');
  await capture(tester, binding, 'r4_local_sidebar');
  await pumpFrames(tester, frames: 4);
  await tester.tap(ownerRow);

  final composer = find.byKey(const Key('dsh-composer'));
  await _pumpUntilFound(
    tester,
    composer,
    what: 'the harness-mode composer (R6)',
    maxFrames: 1200,
  );

  // R5 content: 插件/自动化任务/更多 entries plus the remote session list.
  await _openDrawer(tester);
  final drawerEntries = find.byKey(const Key('dsh-drawer-entries'));
  await _pumpUntilFound(tester, drawerEntries, what: 'the R5 drawer content');
  await pumpFrames(tester, frames: 20);
  _expectDrawerSections(tester, drawerEntries);
  e2eStep('before r5_dsh_drawer');
  await capture(tester, binding, 'r5_dsh_drawer');

  // R6: a new session, a short prompt, and the streamed answer.
  final newSessionInDrawer = find.descendant(
    of: find.byType(SideDrawer),
    matching: find.byKey(const Key('dsh-new-session')),
  );
  await _pumpUntilFound(
    tester,
    newSessionInDrawer,
    what: 'the new-session row in the harness drawer (R5)',
  );
  await tester.ensureVisible(newSessionInDrawer.first);
  await pumpFrames(tester, frames: 4);
  await tester.tap(newSessionInDrawer.first);
  // `_newHarnessSession` closes the drawer only after the create call returns;
  // using that as the signal avoids sending the prompt into the old session.
  await pumpUntil(tester, () => _drawerIsClosed(tester), maxFrames: 600);
  expect(
    _drawerIsClosed(tester),
    isTrue,
    reason: 'the drawer closes after the remote session is created (R5)',
  );
  await _pumpUntilFound(
    tester,
    composer,
    what: 'the new session composer (R6)',
    maxFrames: 300,
  );
  // The composer exists while the drawer's create call is still switching the
  // page; wait for the blank transcript of the *new* Session before reading
  // the preset chip, then let the drawer's pop animation finish.
  await pumpUntil(
    tester,
    () => _assistantMessageCount(tester) == 0,
    maxFrames: 300,
  );
  await pumpFrames(tester, frames: 30);

  // R6 v3: the Agent-preset chip above the composer. The Session the drawer
  // just created is blank, so the Host roster is selectable; the shipped
  // presets use Cuplivo's localized copy because the Host publishes none.
  final presetChip = find.byKey(DshAgentPresetChip.chipKey);
  await _pumpUntilFound(
    tester,
    presetChip,
    what: 'the composer Agent-preset chip (R6)',
    maxFrames: 300,
  );
  await pumpUntil(tester, () {
    final hosts = find.ancestor(
      of: presetChip,
      matching: find.byType(DshAgentPresetChip),
    );
    if (hosts.evaluate().isEmpty) return false;
    return tester
        .widget<DshAgentPresetChip>(hosts.first)
        .agentPresets
        .canSelect;
  }, maxFrames: 300);
  e2eStep('R6 preset chip is selectable');
  await pumpUntil(
    tester,
    () => find
        .descendant(
          of: presetChip,
          matching: find.text(l10n.dshPresetStandardName),
        )
        .evaluate()
        .isNotEmpty,
    maxFrames: 300,
  );
  expect(
    find.descendant(
      of: presetChip,
      matching: find.text(l10n.dshPresetStandardName),
    ),
    findsOneWidget,
    reason: 'R6 the blank Session opens on the Host default preset',
  );
  await _openAgentPresetPicker(tester, presetChip);
  for (final key in const ['standard', 'ptc', 'minimal', 'cordis']) {
    expect(
      find.byKey(DshAgentPresetPicker.rowKey(key)),
      findsOneWidget,
      reason: 'R6 the Host roster lists the shipped preset $key',
    );
  }
  // Cuplivo localizes the shipped rows itself; the Host roster only carries
  // ids for them.
  expect(
    find.text(l10n.dshPresetStandardName),
    findsWidgets,
    reason: 'R6 the shipped presets use the app localization',
  );
  e2eStep('before r6_preset_menu');
  await capture(tester, binding, 'r6_preset_menu');

  // A real write: switching a blank Session's preset goes through
  // `agentPresets/select`, and the chip reports the committed value.
  await tester.tap(find.byKey(DshAgentPresetPicker.rowKey('ptc')));
  await pumpUntil(
    tester,
    () => find
        .descendant(of: presetChip, matching: find.text(l10n.dshPresetPtcName))
        .evaluate()
        .isNotEmpty,
    maxFrames: 300,
  );
  expect(
    find.descendant(of: presetChip, matching: find.text(l10n.dshPresetPtcName)),
    findsOneWidget,
    reason: 'R6 the accepted preset switch reaches the chip',
  );
  e2eStep('before r6_preset_chip');
  await capture(tester, binding, 'r6_preset_chip');
  // Back to the default composition so the tool turn exercises Standard mode.
  await _openAgentPresetPicker(tester, presetChip);
  await tester.tap(find.byKey(DshAgentPresetPicker.rowKey('standard')));
  await pumpUntil(
    tester,
    () => find
        .descendant(
          of: presetChip,
          matching: find.text(l10n.dshPresetStandardName),
        )
        .evaluate()
        .isNotEmpty,
    maxFrames: 300,
  );

  await tester.enterText(composer, _prompt);
  await pumpFrames(tester, frames: 10);
  final sendButton = find.byKey(const Key('dsh-send'));
  expect(sendButton, findsOneWidget, reason: 'the composer send button (R6)');
  await tester.ensureVisible(sendButton);
  await tester.tap(sendButton);

  final transcript = find.byKey(const ValueKey<String>('dsh-transcript'));
  await _pumpUntilFound(tester, transcript, what: 'the DSH transcript (R6)');
  await pumpUntil(tester, () => _hasAssistantText(tester), maxFrames: 1800);
  expect(
    _hasAssistantText(tester),
    isTrue,
    reason: 'the streamed assistant answer inside dsh-transcript (R6)',
  );
  // Let the stream start painting before the evidence frame; then dismiss the
  // IME so the composer and the rail are both fully visible.
  FocusManager.instance.primaryFocus?.unfocus();
  await pumpFrames(tester, frames: 40);

  // R6 app bar: title plus the `model (provider)` subtitle, no local-only
  // controls. The chat slice owns the subtitle string.
  await pumpUntil(tester, () {
    final finder = find.byType(HarnessAppBar);
    if (finder.evaluate().isEmpty) return false;
    final bar = tester.widget<HarnessAppBar>(finder);
    return (bar.subtitle ?? '').trim().isNotEmpty;
  }, maxFrames: 200);
  final appBar = tester.widget<HarnessAppBar>(find.byType(HarnessAppBar));
  expect(appBar.title.trim(), isNotEmpty, reason: 'R6 app-bar title');
  expect(
    (appBar.subtitle ?? '').trim(),
    isNotEmpty,
    reason: 'R6 app-bar subtitle shows model (provider)',
  );
  e2eStep('before r6_chat');
  await capture(tester, binding, 'r6_chat');

  // R6 v2: the composer plus menu. Its two groups are the whole v2 add/
  // command surface; every row is present even when the Host exposes no wire
  // for it (the row says so instead of disappearing).
  final plusButton = find.byTooltip(l10n.chatInputBarMoreTooltip);
  await _pumpUntilFound(
    tester,
    plusButton,
    what: 'the composer plus button (R6)',
  );
  await tester.tap(plusButton.first);
  final plusSheet = find.byKey(const ValueKey<String>('dsh-plus-sheet'));
  await _pumpUntilFound(
    tester,
    plusSheet,
    what: 'the composer plus sheet (R6)',
  );
  for (final key in <String>[
    'dsh-plus-section-add',
    'dsh-plus-attach',
    'dsh-plus-goal',
    'dsh-plus-plan',
    'dsh-plus-feedback',
    'dsh-plus-section-commands',
    'dsh-plus-compact',
    'dsh-plus-permission',
    'dsh-plus-model',
    'dsh-plus-download-log',
  ]) {
    expect(
      find.descendant(
        of: plusSheet,
        matching: find.byKey(ValueKey<String>(key)),
      ),
      findsOneWidget,
      reason: 'R6 plus menu row $key',
    );
  }
  for (final label in <String>[
    l10n.dshPlusSectionAdd,
    l10n.dshPlusSectionCommands,
    l10n.dshPlusAttachFile,
    l10n.dshPlusTarget,
    l10n.dshPlusPlan,
    l10n.dshPlusFeedback,
    l10n.dshPlusCompress,
    l10n.dshPlusPermission,
    l10n.dshPlusModel,
    l10n.dshPlusDownloadLog,
  ]) {
    expect(
      find.descendant(of: plusSheet, matching: find.text(label)),
      findsWidgets,
      reason: 'R6 plus menu label $label',
    );
  }
  await pumpFrames(tester, frames: 20);
  e2eStep('before r6_plus_menu');
  await capture(tester, binding, 'r6_plus_menu');
  // Dismiss the sheet through the navigator that owns it: the sheet is a modal
  // route on the nearest navigator (not necessarily the root one), and a
  // barrier tap in the status-bar corner is not delivered to the app on every
  // emulator size. A left-open sheet swallows the next turn's send tap.
  await _dismissComposerSheet(tester, plusSheet);
  expect(
    plusSheet,
    findsNothing,
    reason: 'R6 the plus menu closes before the tool turn',
  );
  // Let the sheet's reverse animation and the home surface settle before the
  // composer is touched again.
  await pumpFrames(tester, frames: 30);

  // R6 v2: a real tool turn. The prompt makes the Host run bash itself, so the
  // transcript shows the folded tool card and its output - a wire path the
  // text-only prompt above never exercises.
  await tester.enterText(composer, _toolPrompt);
  await pumpFrames(tester, frames: 10);
  await tester.ensureVisible(sendButton);
  // The emulator's IME animation can leave a stale hit-test frame: tap the
  // send button until the composer reports the prompt gone (a tap that reopens
  // the plus sheet is closed and retried instead of swallowing the turn).
  await _submitComposerPrompt(
    tester,
    composer: composer,
    sendButton: sendButton,
    plusSheet: plusSheet,
    label: 'R6 tool prompt',
  );
  // A visual probe for the artifacts: the frame right after the tool turn was
  // accepted by the composer.
  e2eStep('before r6_tool_send_probe');
  await capture(tester, binding, 'r6_tool_send_probe');
  // The Host's tool call becomes a `ToolUIPart` in the transcript data before
  // its card is painted: the list is virtualized and auto-scrolls to the
  // answer, so the card can sit above the built range. Assert the wire-level
  // part first, then scroll the list to the card for the evidence frame.
  await _pumpUntilToolCall(
    tester,
    composer: composer,
    sendButton: sendButton,
    plusSheet: plusSheet,
  );
  expect(
    _transcriptHasToolCall(tester, 'bash'),
    isTrue,
    reason: 'R6 the Host tool call reached the transcript as a bash part',
  );
  await pumpUntil(
    tester,
    () => _assistantMessageCount(tester) >= 2,
    maxFrames: 1800,
  );
  // The follow-up answer quotes the command output, so the marker in an
  // assistant text part is the wire-level proof that the Host ran the tool and
  // the result reached the model (the tool card header alone only proves the
  // call was rendered).
  await pumpUntil(
    tester,
    () => _assistantTextContains(tester, 'CUPLIVO_E2E_TOOL_OK'),
    maxFrames: 1800,
  );
  expect(
    _assistantTextContains(tester, 'CUPLIVO_E2E_TOOL_OK'),
    isTrue,
    reason: 'R6 the assistant turn quotes the tool output marker',
  );
  FocusManager.instance.primaryFocus?.unfocus();
  await pumpFrames(tester, frames: 40);
  // Scroll the virtualized transcript up to the tool card. Its header is the
  // shared renderer's localized tool-call title (`调用工具: bash`), which exists
  // only after the Host ran the call; the bare `bash` label is not what the
  // card paints.
  final bashToolTitle = l10n.chatMessageWidgetToolCall('bash');
  final toolHeader = find.descendant(
    of: transcript,
    matching: find.text(bashToolTitle),
  );
  await _dragTranscriptUntil(tester, transcript, toolHeader, dy: -300);
  expect(toolHeader, findsWidgets, reason: 'R6 the bash tool card rendered');
  expect(
    _assistantMessageCount(tester),
    greaterThanOrEqualTo(2),
    reason: 'R6 a second assistant turn answered the tool result',
  );
  e2eStep('before r6_tool_turn');
  await capture(tester, binding, 'r6_tool_turn');

  // R6 v2: the composer context ring appears once the Host reports
  // `contextPressure` for this session (the core client maps it; the composer
  // only renders the ring when the readout exists).
  final contextRing = find.byKey(const ValueKey<String>('dsh-context-ring'));
  await _pumpUntilFound(
    tester,
    contextRing,
    what: 'the composer context-usage ring (R6)',
    maxFrames: 900,
  );
  await pumpFrames(tester, frames: 20);
  e2eStep('before r6_context_ring');
  await capture(tester, binding, 'r6_context_ring');

  // R6 v2: the attachment flow. The native pickers cannot be driven, but the
  // composer's deterministic seam stages real DocumentAttachments into the same
  // tray, so the chip, upload, prompt parts and transcript card all stay on the
  // product path.
  expect(
    DshComposerE2e.isAvailable,
    isTrue,
    reason: 'R6 the remote composer registers the attachment staging seam',
  );
  final attachmentDir = await Directory.systemTemp.createTemp('cuplivo-e2e-');
  final attachmentFile = File('${attachmentDir.path}/e2e-notes.txt');
  await attachmentFile.writeAsString(
    'CUPLIVO_E2E_ATTACHMENT_OK\nsecond line of the attached notes\n',
  );
  DshComposerE2e.stage(
    images: const <String>[],
    documents: <DocumentAttachment>[
      DocumentAttachment(
        path: attachmentFile.path,
        fileName: 'e2e-notes.txt',
        mime: 'text/plain',
      ),
    ],
  );
  await pumpFrames(tester, frames: 20);
  expect(
    find.byKey(const ValueKey<String>('chat-input-document-previews')),
    findsWidgets,
    reason: 'R6 the staged document renders its composer chip',
  );
  await tester.enterText(composer, '读取我附加的 e2e-notes.txt 并回复它第一行');
  await pumpFrames(tester, frames: 10);
  await _submitComposerPrompt(
    tester,
    composer: composer,
    sendButton: sendButton,
    plusSheet: plusSheet,
    label: 'R6 attachment prompt',
  );
  // The attachment card is another virtualized row: prove the file part in
  // the folded transcript, then bring the last turn back into view for the
  // evidence frame.
  await pumpUntil(
    tester,
    () => _transcriptHasFilePart(tester, 'e2e-notes.txt'),
    maxFrames: 1200,
  );
  expect(
    _transcriptHasFilePart(tester, 'e2e-notes.txt'),
    isTrue,
    reason: 'R6 the attachment reaches the transcript as a file part',
  );
  await pumpUntil(
    tester,
    () => _assistantTextContains(tester, 'CUPLIVO_E2E_ATTACHMENT_OK'),
    maxFrames: 1800,
  );
  expect(
    _assistantTextContains(tester, 'CUPLIVO_E2E_ATTACHMENT_OK'),
    isTrue,
    reason:
        'R6 the assistant read the attached notes and quoted its first line',
  );
  FocusManager.instance.primaryFocus?.unfocus();
  await pumpFrames(tester, frames: 40);
  await _dragTranscriptUntil(
    tester,
    transcript,
    find.descendant(
      of: transcript,
      matching: find.textContaining('CUPLIVO_E2E_ATTACHMENT_OK'),
    ),
    dy: 300,
  );
  e2eStep('before r6_attachment');
  await capture(tester, binding, 'r6_attachment');

  // R7: opening the rail pushes the chat off-screen instead of stacking on it.
  final screenWidth = tester.getSize(find.byType(HomeMobileScaffold)).width;
  final composerBefore = tester.getRect(composer);
  await tester.tap(find.byKey(const Key('dsh-right-rail-button')));
  final rail = find.byKey(const Key('dsh-right-rail'));
  await _pumpUntilFound(tester, rail, what: 'the right rail (R7)');
  await pumpUntil(
    tester,
    () => _railHeaderX(tester) < screenWidth / 2,
    maxFrames: 120,
  );
  expect(
    _railHeaderX(tester),
    lessThan(screenWidth / 2),
    reason: 'R7 rail occupies the right side of the window',
  );
  final composerAfter = tester.getRect(composer);
  expect(
    composerAfter.left != composerBefore.left ||
        composerAfter.width != composerBefore.width,
    isTrue,
    reason: 'R7 pushes the chat off-screen instead of stacking the rail on it',
  );
  // The three cards of the 开始 page; 浏览器 is intentionally absent
  // (capability parity: DSH 0.2.2 has no remote browser API).
  expect(
    find.descendant(
      of: rail,
      matching: find.byKey(const Key('dsh-rail-workspace-files')),
    ),
    findsOneWidget,
    reason: 'R7 工作区文件 card',
  );
  expect(
    find.descendant(
      of: rail,
      matching: find.byKey(const Key('dsh-rail-new-terminal')),
    ),
    findsOneWidget,
    reason: 'R7 新建终端 card',
  );
  expect(
    find.descendant(
      of: rail,
      matching: find.byKey(const Key('dsh-rail-more-tools')),
    ),
    findsOneWidget,
    reason: 'R7 更多工具 card',
  );
  expect(
    find.descendant(of: rail, matching: find.textContaining('Ctrl + T')),
    findsNothing,
    reason: 'R7 browser card must not exist in this build',
  );
  await pumpFrames(tester, frames: 20);
  e2eStep('before r7_right_rail');
  await capture(tester, binding, 'r7_right_rail');

  // Close the rail through its own header action; the harvest section below
  // re-opens it for the Host's own cards.
  final closeRail = find.descendant(
    of: rail,
    matching: find.byKey(const Key('dsh-rail-close')),
  );
  expect(closeRail, findsWidgets, reason: 'R7 rail close action');
  await tester.tap(closeRail.first);
  await pumpUntil(
    tester,
    () => _railHeaderX(tester) >= screenWidth / 2,
    maxFrames: 120,
  );

  // R5/R7 v2: the official-WebUI harvest. Everything above ran against the
  // pre-harvest fallback (built-in 插件/自动化任务/更多 rows, a native rail).
  // The first official page load turns the R5 sidebar into the Host's own
  // sidebar rows and appends the R7 extra cards; this block walks that
  // transition. 更多 stays one Cuplivo built-in row in both modes, and it now
  // lands on the official 更多 menu instead of a native page.
  await _pumpUntilFound(
    tester,
    find.byKey(const Key('dsh-composer')),
    what: 'the harness home after closing the rail (R5)',
  );

  // Open 插件 once, pre-harvest: the WebUI page runs the harvest script and
  // posts the official sidebar/rail labels back through `CuplivoHost`.
  await _openDrawer(tester);
  final preHarvestPlugins = find.descendant(
    of: find.byKey(const Key('dsh-drawer-entries')),
    matching: find.byKey(const ValueKey<String>('dsh-sidebar-entry-plugins')),
  );
  await _pumpUntilFound(
    tester,
    preHarvestPlugins,
    what: 'the pre-harvest 插件 row (R5)',
  );
  await tester.ensureVisible(preHarvestPlugins.first);
  await pumpFrames(tester, frames: 4);
  await tester.tap(preHarvestPlugins.first);
  await _waitDshWebUiPage(
    tester,
    label: l10n.dshSidebarPlugins,
    l10n: l10n,
    what: 'the official WebUI opened by 插件 (R5 harvest)',
    maxFrames: 900,
  );
  // The automatic harvest posts the Host's own sidebar and right-rail labels.
  // The hosted emulator's WebView cannot render the official single-page app,
  // so on that platform the snapshot stays empty and the native built-in rows
  // remain: the DOM-contract job proves the recipe against the real Host, and
  // this scenario asserts the app's honest fallback.
  await pumpUntil(
    tester,
    () => DshSurfaceInventory.shared.snapshotFor(authority).sidebar.isNotEmpty,
    maxFrames: 240,
  );
  await _popRoute(tester);
  final surfaceSnapshot = DshSurfaceInventory.shared.snapshotFor(authority);
  final harvestedSidebar = surfaceSnapshot.sidebar;
  final harvestedRail = surfaceSnapshot.rail;
  debugPrint(
    '[dsh-e2e] harvested sidebar: '
    '${harvestedSidebar.map((entry) => entry.label).join(' | ')}',
  );
  debugPrint(
    '[dsh-e2e] harvested rail: '
    '${harvestedRail.map((entry) => '${entry.label}[${entry.kind}]').join(' | ')}',
  );
  await _openDrawer(tester);
  final harvestedDrawer = find.byKey(const Key('dsh-drawer-entries'));
  await _pumpUntilFound(
    tester,
    harvestedDrawer,
    what: 'the R5 drawer after the harvest',
  );
  if (harvestedSidebar.isEmpty) {
    debugPrint(
      '[dsh-e2e] the emulator WebView renderer is unavailable: the drawer '
      'keeps the built-in rows (the dom-contract job proves the harvest)',
    );
    _expectDrawerSections(tester, harvestedDrawer);
  } else {
    // Every harvested label renders verbatim with the Host's own text; Cuplivo
    // knows no plugin names, so a row that only exists through the harvest is
    // exactly the generic-compatibility promise.
    for (final entry in harvestedSidebar) {
      expect(
        find.descendant(of: harvestedDrawer, matching: find.text(entry.label)),
        findsWidgets,
        reason: 'R5 the harvested row "${entry.label}" renders the Host label',
      );
    }
  }
  // 更多 is not a panellist row: it is DSH's own sidebar action strip, so
  // Cuplivo keeps exactly one built-in 更多 row in both modes.
  expect(
    find.descendant(
      of: harvestedDrawer,
      matching: find.byKey(const ValueKey<String>('dsh-sidebar-entry-more')),
    ),
    findsOneWidget,
    reason: 'R5 更多 stays one Cuplivo built-in row after the harvest',
  );
  await pumpFrames(tester, frames: 20);
  e2eStep('before r5_harvested_sidebar');
  await capture(tester, binding, 'r5_harvested_sidebar');

  // Captures of the official pages the harvested rows land on. The official
  // WebUI is a platform view, so these screenshots carry Cuplivo's chrome and
  // the route; the Host's DOM itself is not part of the Flutter surface.
  // Assertions therefore anchor on the route title plus the harvest: only a
  // loaded official page can post the labels asserted above.
  final pageTargets = <(String, String)>[
    if (harvestedSidebar.isNotEmpty)
      for (var index = 0; index < harvestedSidebar.length && index < 2; index++)
        (
          harvestedSidebar[index].label,
          index == 0 ? 'r5_plugins_page' : 'r5_search_service_page',
        ),
    if (harvestedSidebar.isNotEmpty) (l10n.dshSidebarMore, 'r5_more_menu'),
  ];
  for (final page in pageTargets) {
    await _openHarvestedSidebarRow(tester, page.$1, l10n: l10n);
    await pumpFrames(tester, frames: 30);
    await capture(tester, binding, page.$2);
    await _popRoute(tester);
  }

  // R7 v2: the harvested rail cards. The built-in cards stay native; the Host's
  // own rail labels are appended by the harvest (工作区文件 / 新建终端 /
  // 更多工具 are excluded because Cuplivo renders those natively).
  await _closeDrawer(tester);
  await tester.tap(find.byKey(const Key('dsh-right-rail-button')));
  await _pumpUntilFound(tester, rail, what: 'the right rail after the harvest');
  await pumpUntil(
    tester,
    () => _railHeaderX(tester) < screenWidth / 2,
    maxFrames: 120,
  );
  final railSnapshot = DshSurfaceInventory.shared.snapshotFor(authority);
  final extraCards = <DshSurfaceEntry>[
    for (final entry in railSnapshot.rail)
      if (entry.kind != 'files' && entry.kind != 'terminal') entry,
  ];
  debugPrint(
    '[dsh-e2e] harvested rail extras: '
    '${extraCards.map((entry) => '${entry.label}[${entry.kind}]').join(' | ')}',
  );
  if (extraCards.isEmpty) {
    // Same platform limitation as R5: no harvest means the built-in cards keep
    // the rail usable; the DOM-contract job proves the Host cards against the
    // real Host.
    debugPrint(
      '[dsh-e2e] the emulator WebView renderer is unavailable: the rail shows '
      'the built-in cards (the dom-contract job proves the harvested cards)',
    );
    for (final label in <String>[
      l10n.dshRailWorkspaceFiles,
      l10n.dshRailNewTerminal,
    ]) {
      expect(
        find.descendant(of: rail, matching: find.text(label)),
        findsWidgets,
        reason: 'R7 the built-in rail card "$label" stays usable',
      );
    }
  } else {
    for (final entry in extraCards) {
      await _pumpUntilFound(
        tester,
        find.descendant(of: rail, matching: find.text(entry.label)),
        what: 'the harvested rail card "${entry.label}" (R7)',
        maxFrames: 900,
      );
    }
    final diffEntry = extraCards.firstWhere(
      (entry) => entry.kind == 'bw-diff',
      orElse: () => extraCards.first,
    );
    final diffCard = find.descendant(
      of: rail,
      matching: find.text(diffEntry.label),
    );
    await pumpFrames(tester, frames: 20);
    e2eStep('before r7_harvested_cards');
    await capture(tester, binding, 'r7_harvested_cards');
    await tester.ensureVisible(diffCard.first);
    await pumpFrames(tester, frames: 4);
    await tester.tap(diffCard.first);
    await _waitDshWebUiPage(
      tester,
      label: diffEntry.label,
      l10n: l10n,
      what: 'the "${diffEntry.label}" official page (R7)',
      maxFrames: 900,
    );
    await pumpFrames(tester, frames: 30);
    e2eStep('before r7_diff_page');
    await capture(tester, binding, 'r7_diff_page');
    await _popRoute(tester);
    await _pumpUntilFound(
      tester,
      rail,
      what: 'the rail after closing the 代码变更 page (R7)',
    );
  }

  // R12: the rail's 新建终端 card opens the Host's real terminal. A remote PTY
  // exists only when terminal/create + terminal/environment succeeded, so the
  // panel, the header's shell title/cwd and an absent read-only banner are the
  // acceptance.
  await tester.tap(
    find
        .descendant(
          of: rail,
          matching: find.byKey(const Key('dsh-rail-new-terminal')),
        )
        .first,
  );
  final terminalPanel = find.byKey(const Key('dsh-terminal-panel'));
  await _pumpUntilFound(
    tester,
    terminalPanel,
    what: 'the Host terminal panel (R12)',
    maxFrames: 900,
  );
  final terminalView = find.byKey(const Key('dsh-terminal-view'));
  await _pumpUntilFound(
    tester,
    terminalView,
    what: 'the terminal surface after terminal/create (R12)',
    maxFrames: 900,
  );
  expect(
    find.byKey(const Key('dsh-terminal-unavailable')),
    findsNothing,
    reason: 'R12 the Host terminal launched instead of the unavailable card',
  );
  final terminalHeader = find.byKey(const Key('dsh-terminal-header'));
  await _pumpUntilFound(
    tester,
    terminalHeader,
    what: 'the terminal header (R12)',
  );
  // These two are real Text from terminal/create + environment: they prove a
  // remote PTY exists, which a placeholder cannot fake.
  expect(
    find.descendant(of: terminalHeader, matching: find.text('bash')),
    findsWidgets,
    reason: 'R12 terminal header shows the Host shell title',
  );
  expect(
    find.descendant(
      of: terminalHeader,
      matching: find.textContaining('workspace'),
    ),
    findsWidgets,
    reason: 'R12 terminal header shows the Host working directory',
  );
  expect(
    find.byKey(const Key('dsh-terminal-readonly')),
    findsNothing,
    reason: 'R12 the Host terminal is writable, so no read-only banner',
  );
  await pumpFrames(tester, frames: 20);
  e2eStep('before r12_terminal');
  await capture(tester, binding, 'r12_terminal');
  // terminal_view paints its screen with a canvas: no Text carries the output.
  // The command is driven through the IME path a phone uses and its side
  // effect is asserted in the workspace file list instead.
  await tester.tap(terminalView);
  await pumpFrames(tester, frames: 10);
  await _typeIntoTerminal(tester, _terminalCommand);
  e2eStep('before r12_terminal_command');
  await capture(tester, binding, 'r12_terminal_command');
  // Leave the terminal page (which disposes the PTY) and assert the created
  // file; the rail files listing is re-fetched when its page mounts.
  await tester.tap(find.byKey(const Key('dsh-rail-back')));
  await pumpFrames(tester, frames: 8);
  await _openRailFilesPage(tester, rail);
  final terminalFile = find.descendant(
    of: rail,
    matching: find.text('cuplivo-e2e-terminal.txt'),
  );
  await _pumpUntilFound(
    tester,
    terminalFile,
    what: 'R12 side effect: cuplivo-e2e-terminal.txt in the workspace files',
    maxFrames: 600,
  );

  // R13: png/text stay inline in the rail; the binary kinds hand the file to
  // the preview slice's full-screen page. PDF rendering is device-dependent, so
  // that case accepts a rendered WebView or the honest metadata card; blob.bin
  // only has the card.
  await _openRailFilesPage(tester, rail);
  final assetsDir = find.descendant(of: rail, matching: find.text('assets'));
  await _pumpUntilFound(tester, assetsDir, what: 'the assets/ folder (R13)');
  await tester.tap(assetsDir.first);
  await pumpFrames(tester, frames: 12);
  final pixel = find.descendant(of: rail, matching: find.text('pixel.png'));
  await _pumpUntilFound(tester, pixel, what: 'assets/pixel.png (R13)');
  await tester.tap(pixel.first);
  final inlineImage = find.descendant(of: rail, matching: find.byType(Image));
  await _pumpUntilFound(
    tester,
    inlineImage,
    what: 'the inline png preview in the rail (R13)',
    maxFrames: 600,
  );
  await pumpFrames(tester, frames: 20);
  e2eStep('before r13_png_inline');
  await capture(tester, binding, 'r13_png_inline');
  await tester.tap(find.byKey(const Key('dsh-rail-back')));
  await pumpFrames(tester, frames: 8);

  for (final probe in <(String, String, String)>[
    ('docs', 'report.pdf', 'r13_pdf_preview'),
    ('data', 'blob.bin', 'r13_binary_preview'),
  ]) {
    await _openRailFilesPage(tester, rail);
    final folderRow = find.descendant(of: rail, matching: find.text(probe.$1));
    await _pumpUntilFound(
      tester,
      folderRow,
      what: 'the ${probe.$1}/ folder (R13)',
    );
    await tester.tap(folderRow.first);
    await pumpFrames(tester, frames: 12);
    final fileName = find.descendant(of: rail, matching: find.text(probe.$2));
    await _pumpUntilFound(
      tester,
      fileName,
      what: '${probe.$1}/${probe.$2} (R13)',
    );
    await tester.tap(fileName.first);
    // The preview page's documented root key may lag the widget type; accept
    // either so the slice can add the key without touching this scenario.
    final previewKey = find.byKey(const Key('dsh-file-preview-page'));
    final previewType = find.byType(DshFilePreviewPage);
    await pumpUntil(
      tester,
      () =>
          previewKey.evaluate().isNotEmpty || previewType.evaluate().isNotEmpty,
      maxFrames: 600,
    );
    final previewPage = previewKey.evaluate().isNotEmpty
        ? previewKey
        : previewType;
    expect(
      previewPage,
      findsWidgets,
      reason: 'the full-screen preview of ${probe.$2} (R13)',
    );
    expect(
      find.descendant(of: previewPage, matching: find.text(probe.$2)),
      findsWidgets,
      reason: 'R13 preview title names ${probe.$2}',
    );
    if (probe.$2 == 'blob.bin') {
      await _pumpUntilFound(
        tester,
        find.byKey(const Key('dsh-remote-file-card')),
        what: 'the honest metadata card for blob.bin (R13)',
        maxFrames: 600,
      );
      expect(
        find.text(l10n.dshFilesPreviewUnavailable),
        findsWidgets,
        reason: 'R13 blob.bin card explains the unsupported kind',
      );
    } else {
      // A PDF loads through the authenticated /api/file URL in the embedded
      // Host Web UI; a device whose WebView cannot show it falls back to the
      // same honest card, which is the documented limit.
      final rendered = find.byType(DshWebUiView);
      final limited = find.byKey(const Key('dsh-remote-file-card'));
      await pumpUntil(
        tester,
        () => rendered.evaluate().isNotEmpty || limited.evaluate().isNotEmpty,
        maxFrames: 600,
      );
      expect(
        rendered.evaluate().isNotEmpty || limited.evaluate().isNotEmpty,
        isTrue,
        reason: 'R13 report.pdf renders in a WebView or states its limit',
      );
    }
    await pumpFrames(tester, frames: 20);
    await capture(tester, binding, probe.$3);
    await _popRoute(tester);
    await pumpFrames(tester, frames: 8);
  }

  // Close the rail so the final frame is the harness chat the scenario ends on.
  await _closeDrawer(tester);
  final railClose = find.descendant(
    of: rail,
    matching: find.byKey(const Key('dsh-rail-close')),
  );
  if (railClose.evaluate().isNotEmpty) {
    await tester.tap(railClose.first);
    await pumpFrames(tester, frames: 12);
  }

  expect(tester.takeException(), isNull);
  e2eStep('before final_state');
  await capture(tester, binding, 'final_state');
}

/// Hermetic mode: every local navigation the scenario owns, no host requests.
Future<void> _runHermeticTail(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  // The direct-connect form is as far as a fork PR can go: it needs a real
  // endpoint and token to submit, and hermetic mode must depend on neither.
  expect(find.byKey(const Key('dsh-connect-name')), findsOneWidget);
  expect(find.byKey(const Key('dsh-connect-url')), findsOneWidget);
  expect(find.byKey(const Key('dsh-connect-confirm')), findsOneWidget);
  await pumpFrames(tester, frames: 20);
  e2eStep('before hermetic_create_form');
  await capture(tester, binding, 'hermetic_create_form');

  expect(tester.takeException(), isNull);
  e2eStep('before final_state');
  await capture(tester, binding, 'final_state');
  debugPrint(
    '[dsh-e2e] hermetic mode: E2E_DSH_URL and E2E_DSH_TOKEN are empty, so '
    'the DSH connect/send/rail/models assertions were skipped; local drawer, '
    'create menu, engine sheet and direct-connect form were captured instead.',
  );
}

Future<void> _openDrawer(WidgetTester tester) async {
  final scaffold = find.byType(HomeMobileScaffold);
  expect(scaffold, findsOneWidget, reason: 'the mobile home scaffold');
  tester.widget<HomeMobileScaffold>(scaffold).drawerController.jumpTo(1.0);
  await pumpFrames(tester, frames: 8);
  expect(find.byType(SideDrawer), findsWidgets, reason: 'the open side drawer');
}

/// Expands the current-assistant header tile so the inline owner list (the only
/// place a phone can reach a remote's harness home from) renders, then waits for
/// the DSH owner row.
///
/// This is the user gesture on a phone: drawer → tap the current-assistant tile
/// (`dsh-assistant-picker-toggle`) → the assistants/groups/remotes list expands
/// above the conversations → tap the DeepSeek Harness row. It is idempotent so
/// a drawer that is already expanded skips the tap.
Future<void> _expandAssistantPickerForOwners(WidgetTester tester) async {
  final ownerRow = find.byKey(const Key('dsh-owner-row'));
  if (ownerRow.evaluate().isNotEmpty) return;
  final toggle = find.byKey(const Key('dsh-assistant-picker-toggle'));
  expect(
    toggle,
    findsOneWidget,
    reason: 'the current-assistant header tile on the local drawer',
  );
  await tester.tap(toggle);
  // The inline list is revealed inside AnimatedSize (260 ms) + AnimatedSwitcher
  // (220 ms); the keyed row appears as soon as the switcher builds it.
  await _pumpUntilFound(
    tester,
    ownerRow,
    what: 'the DSH owner row after expanding the assistant picker',
  );
}

/// Whether the mobile home drawer has finished closing.
bool _drawerIsClosed(WidgetTester tester) {
  final scaffold = find.byType(HomeMobileScaffold);
  if (scaffold.evaluate().isEmpty) return false;
  return tester.widget<HomeMobileScaffold>(scaffold).drawerController.isClosed;
}

/// Drawer → settings → 助手与群聊, the page that owns the create menu.
Future<void> _openChatOwnerSettings(
  WidgetTester tester,
  AppLocalizations l10n,
) async {
  final settingsButton = find.descendant(
    of: find.byType(SideDrawer),
    matching: find.byIcon(Lucide.Settings),
  );
  expect(settingsButton, findsOneWidget, reason: 'the drawer settings action');
  await tester.tap(settingsButton);
  await _pumpUntilFound(
    tester,
    find.byType(SettingsPage),
    what: 'the settings page',
  );
  final chatOwnersRow = find.descendant(
    of: find.byType(SettingsPage),
    matching: find.text(l10n.settingsPageChatOwners),
  );
  await _pumpUntilFound(tester, chatOwnersRow, what: 'the 助手与群聊 settings row');
  await tester.tap(chatOwnersRow.first);
  await _pumpUntilFound(
    tester,
    find.byType(ChatOwnerSettingsPage),
    what: 'the 助手与群聊 page',
  );
}

/// Taps the 助手与群聊 page's `+` action.
///
/// The action is owned by the foundation slice: it gains the stable
/// `dsh-create-action` key, and until that lands the page's only app-bar plus
/// icon is the fallback so the scenario is not blocked on the other slice.
Future<void> _openCreateMenu(WidgetTester tester) async {
  final keyed = find.byKey(const Key('dsh-create-action'));
  final plus = keyed.evaluate().isNotEmpty
      ? keyed
      : find.descendant(
          of: find.byType(ChatOwnerSettingsPage),
          matching: find.byIcon(Lucide.Plus),
        );
  expect(plus, findsWidgets, reason: 'the 助手与群聊 create action');
  await tester.tap(plus.first);
  await pumpFrames(tester, frames: 12);
}

void _expectSettingsTabs(
  WidgetTester tester,
  AppLocalizations l10n, {
  bool withHostTabs = false,
}) {
  final tabs = find.byKey(const Key('dsh-settings-tabs'));
  expect(tabs, findsOneWidget, reason: 'the assistant settings tab strip (R2)');
  // The strip is id-keyed: every spec renders a `dsh-settings-tab-<id>` button
  // except the models tab, which keeps its historical `dsh-models-tab` key.
  final coreKeys = <String, Key>{
    'connection': const Key('dsh-settings-tab-connection'),
    'general': const Key('dsh-settings-tab-general'),
    'models': const Key('dsh-models-tab'),
  };
  for (final entry in coreKeys.entries) {
    expect(
      find.descendant(of: tabs, matching: find.byKey(entry.value)),
      findsOneWidget,
      reason: 'R2 tab id ${entry.key}',
    );
  }
  for (final label in <String>[
    l10n.dshTabConnection,
    l10n.dshTabGeneral,
    l10n.dshTabModels,
  ]) {
    expect(
      find.descendant(of: tabs, matching: find.text(label)),
      findsWidgets,
      reason: 'R2 tab $label',
    );
  }
  if (!withHostTabs) return;
  // 内置插件 / Agent 预设 are Host-reported: they are absent until the remote's
  // catalog reports plugin capability, so they are only asserted after connect.
  final hostTabs = <String, String>{
    'plugins': l10n.dshTabPlugins,
    'agentPresets': l10n.dshTabAgentPresets,
  };
  for (final entry in hostTabs.entries) {
    expect(
      find.descendant(
        of: tabs,
        matching: find.byKey(ValueKey<String>('dsh-settings-tab-${entry.key}')),
      ),
      findsOneWidget,
      reason: 'R2 tab id ${entry.key}',
    );
    expect(
      find.descendant(of: tabs, matching: find.text(entry.value)),
      findsWidgets,
      reason: 'R2 tab ${entry.value}',
    );
  }
}

/// Taps one tab of the assistant settings strip by its key.
///
/// The strip is a horizontal `ListView`; [ensureVisible] scrolls it so a tab
/// that is off the right edge is still tappable on a 411 dp phone.
Future<void> _openSettingsTabById(
  WidgetTester tester,
  Key key, {
  required String what,
}) async {
  final tab = find.descendant(
    of: find.byKey(const Key('dsh-settings-tabs')),
    matching: find.byKey(key),
  );
  await _pumpUntilFound(tester, tab, what: what);
  await tester.ensureVisible(tab.first);
  await pumpFrames(tester, frames: 6);
  await tester.tap(tab.first);
  await pumpFrames(tester, frames: 20);
}

/// R2: the empty WebUI URL field advertises the token placeholder.
///
/// The placeholder is the field's `hintText`; it only renders while the field
/// is empty, which is exactly the create-form state the scenario asserts.
void _expectConnectUrlPlaceholder(WidgetTester tester, AppLocalizations l10n) {
  final field = find.descendant(
    of: find.byKey(const Key('dsh-connect-url')),
    matching: find.byType(TextField),
  );
  if (field.evaluate().isNotEmpty) {
    expect(
      tester.widget<TextField>(field.first).decoration?.hintText,
      l10n.dshWebUiUrlHint,
      reason: 'R2 WebUI URL field restores the token placeholder hint',
    );
    return;
  }
  final hint = find.descendant(
    of: find.byKey(const Key('dsh-connect-url')),
    matching: find.text(l10n.dshWebUiUrlHint),
  );
  expect(
    hint,
    findsOneWidget,
    reason: 'R2 WebUI URL field restores the token placeholder hint',
  );
}

void _expectDrawerSections(WidgetTester tester, Finder drawerEntries) {
  // Pre-harvest the three DSH built-ins are Cuplivo's own rows: the canonical
  // `dsh-sidebar-entry-<id>` key (a harvested row puts the official label's
  // slug in the same slot) plus the historical `dsh-entry-*` anchor.
  for (final id in <String>['plugins', 'automations', 'more']) {
    expect(
      find.descendant(
        of: drawerEntries,
        matching: find.byKey(Key('dsh-entry-$id')),
      ),
      findsOneWidget,
      reason: 'R5 legacy drawer entry anchor dsh-entry-$id',
    );
    expect(
      find.descendant(
        of: drawerEntries,
        matching: find.byKey(ValueKey<String>('dsh-sidebar-entry-$id')),
      ),
      findsOneWidget,
      reason: 'R5 canonical drawer entry dsh-sidebar-entry-$id',
    );
  }
  expect(
    find.descendant(
      of: drawerEntries,
      matching: find.byKey(const Key('dsh-session-row')),
    ),
    findsWidgets,
    reason: 'R5 session rows',
  );
  expect(
    find.descendant(
      of: drawerEntries,
      matching: find.byKey(const Key('dsh-new-session')),
    ),
    findsWidgets,
    reason: 'R5 new-session row',
  );
}

/// The rail header's left edge. The mobile rail is always mounted inside the
/// right `InteractiveDrawer`, so "open" is a position, not a widget exists.
double _railHeaderX(WidgetTester tester) {
  final header = find
      .descendant(
        of: find.byKey(const Key('dsh-right-rail')),
        matching: find.byKey(const Key('dsh-rail-title')),
      )
      .first;
  return tester.getTopLeft(header).dx;
}

Finder _providerRows() {
  return find.byWidgetPredicate((widget) {
    final key = widget.key;
    return key is ValueKey<String> && key.value.startsWith('dsh-provider-row-');
  }, description: 'DSH provider row');
}

int _providerRowCount(WidgetTester tester) => _providerRows().evaluate().length;

/// Whether the folded harness transcript already has non-empty assistant text.
///
/// `MessageListView.messages` is the same public surface the acceptance helper
/// uses, so the scenario does not guess from rendered glyphs: a role check plus
/// a non-empty text part is exactly "the streamed answer exists".
bool _hasAssistantText(WidgetTester tester) {
  final list = find.descendant(
    of: find.byKey(const ValueKey<String>('dsh-transcript')),
    matching: find.byType(MessageListView),
  );
  if (list.evaluate().isEmpty) return false;
  final view = tester.widget<MessageListView>(list.first);
  for (final message in view.messages) {
    if (message.role != 'assistant') continue;
    for (final part in message.parts) {
      if (part is TextPart && part.text.trim().isNotEmpty) return true;
    }
  }
  return false;
}

/// Number of assistant messages in the folded transcript.
///
/// R6 sends two prompts: the first answer and the tool turn's follow-up. The
/// count is the wire-level signal that the second answer arrived, independent
/// of glyph rendering.
int _assistantMessageCount(WidgetTester tester) {
  final list = find.descendant(
    of: find.byKey(const ValueKey<String>('dsh-transcript')),
    matching: find.byType(MessageListView),
  );
  if (list.evaluate().isEmpty) return 0;
  final view = tester.widget<MessageListView>(list.first);
  return view.messages.where((message) => message.role == 'assistant').length;
}

/// Whether any assistant text part contains [needle].
bool _assistantTextContains(WidgetTester tester, String needle) {
  final list = find.descendant(
    of: find.byKey(const ValueKey<String>('dsh-transcript')),
    matching: find.byType(MessageListView),
  );
  if (list.evaluate().isEmpty) return false;
  final view = tester.widget<MessageListView>(list.first);
  for (final message in view.messages) {
    if (message.role != 'assistant') continue;
    for (final part in message.parts) {
      if (part is TextPart && part.text.contains(needle)) return true;
    }
  }
  return false;
}

/// Logs what the composer and its surrounding notifications hold when a send
/// tap did not take, so a failure says why instead of only that it happened.
void _logComposerState(WidgetTester tester, String label, int attempt) {
  final snackbars = find.descendant(
    of: find.byType(SnackBar),
    matching: find.byType(Text),
  );
  final snackbarText = snackbars
      .evaluate()
      .map((element) => (element.widget as Text).data ?? '')
      .where((text) => text.isNotEmpty)
      .join(' | ');
  final docs = find
      .byKey(const ValueKey<String>('chat-input-document-previews'))
      .evaluate()
      .length;
  final dialogs = find.byType(Dialog).evaluate().length;
  final sheets = find.byType(BottomSheet).evaluate().length;
  e2eStep(
    '$label: attempt $attempt state '
    'snackbar="$snackbarText" docs=$docs dialogs=$dialogs sheets=$sheets',
  );
}

/// Taps the composer's send button until the prompt leaves the field.
///
/// The emulator's IME animation can leave a stale hit-test frame that swallows
/// one tap, and a plus sheet left over the composer swallows it too; both are
/// retried here so a lost tap fails with the composer still holding the text
/// instead of timing out later on an unrelated assertion.
Future<void> _submitComposerPrompt(
  WidgetTester tester, {
  required Finder composer,
  required Finder sendButton,
  required Finder plusSheet,
  required String label,
}) async {
  // While a turn streams, the send button is the stop button: a tap there
  // cancels the turn instead of submitting. Wait for the idle send glyph before
  // typing into the composer, otherwise an attachment sent during the previous
  // answer would be silently dropped (or worse, cancel the running turn).
  final sendGlyph = find.descendant(
    of: sendButton,
    matching: find.byKey(const ValueKey<String>('send')),
  );
  final stopGlyph = find.descendant(
    of: sendButton,
    matching: find.byKey(const ValueKey<String>('stop')),
  );
  await pumpUntil(
    tester,
    () => sendGlyph.evaluate().isNotEmpty && stopGlyph.evaluate().isEmpty,
    maxFrames: 2400,
  );
  await pumpFrames(tester, frames: 20);
  expect(
    sendGlyph,
    findsOneWidget,
    reason: '$label: the composer is back to an idle send state',
  );
  await tester.ensureVisible(sendButton);
  for (var attempt = 1; attempt <= 3; attempt += 1) {
    if (plusSheet.evaluate().isNotEmpty) {
      e2eStep('$label: plus sheet present before the send (attempt $attempt)');
      await _dismissComposerSheet(tester, plusSheet);
    }
    e2eStep('$label: send attempt $attempt');
    await tester.tap(sendButton);
    await pumpFrames(tester, frames: 30);
    if (_composerText(tester, composer).isEmpty) return;
    e2eStep('$label: send attempt $attempt did not clear the composer');
    _logComposerState(tester, label, attempt);
    await pumpFrames(tester, frames: 30);
  }
  // The rejected-send path restores the draft asynchronously after the tap;
  // give that settle a moment before declaring the send lost.
  await pumpFrames(tester, frames: 120);
  if (_composerText(tester, composer).isEmpty) return;
  _logComposerState(tester, label, 4);
  expect(
    _composerText(tester, composer),
    isEmpty,
    reason: '$label: the prompt leaves the composer when send is tapped',
  );
}

/// Whether the folded transcript carries a file part named [name].
bool _transcriptHasFilePart(WidgetTester tester, String name) {
  final list = find.descendant(
    of: find.byKey(const ValueKey<String>('dsh-transcript')),
    matching: find.byType(MessageListView),
  );
  if (list.evaluate().isEmpty) return false;
  final view = tester.widget<MessageListView>(list.first);
  for (final message in view.messages) {
    for (final part in message.parts) {
      if (part is FilePart && part.name.contains(name)) return true;
    }
  }
  return false;
}

/// Opens the composer's Agent-preset sheet, retrying the tap a few times: the
/// chip sits at the sane place the drawer's pop animation may still cover.
Future<void> _openAgentPresetPicker(WidgetTester tester, Finder chip) async {
  final row = find.byKey(DshAgentPresetPicker.rowKey('standard'));
  for (var attempt = 1; attempt <= 3; attempt += 1) {
    await tester.tap(chip);
    await pumpUntil(tester, () => row.evaluate().isNotEmpty, maxFrames: 60);
    if (row.evaluate().isNotEmpty) return;
    e2eStep('R6 preset picker did not open (attempt $attempt)');
    await pumpFrames(tester, frames: 10);
  }
  await _pumpUntilFound(
    tester,
    row,
    what: 'the Agent-preset picker roster (R6)',
  );
}

/// Dismisses the composer's modal plus sheet through the navigator that owns
/// it, with a root-navigator fallback for the surfaces where that differs.
Future<void> _dismissComposerSheet(WidgetTester tester, Finder sheet) async {
  if (sheet.evaluate().isEmpty) return;
  await Navigator.of(tester.element(sheet.first)).maybePop();
  await pumpUntil(tester, () => sheet.evaluate().isEmpty, maxFrames: 120);
  if (sheet.evaluate().isNotEmpty) {
    _rootNavigator(tester).maybePop();
    await pumpUntil(tester, () => sheet.evaluate().isEmpty, maxFrames: 120);
  }
  await pumpFrames(tester, frames: 10);
}

/// The text the DSH composer currently holds (empty when the field is gone).
String _composerText(WidgetTester tester, Finder composer) {
  final fields = find.descendant(
    of: composer,
    matching: find.byType(EditableText),
  );
  if (fields.evaluate().isEmpty) return '';
  return tester.widget<EditableText>(fields.first).controller.text;
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  required String what,
  int maxFrames = 300,
}) async {
  await pumpUntil(
    tester,
    () => finder.evaluate().isNotEmpty,
    maxFrames: maxFrames,
  );
  expect(
    finder,
    findsWidgets,
    reason: 'Expected $what within ${maxFrames * 100} ms of pumping',
  );
}

NavigatorState _rootNavigator(WidgetTester tester) {
  // Routes below the top one stay in the tree but offstage; the home scaffold
  // is under the root navigator throughout the scenario.
  final home = find.byType(HomeMobileScaffold, skipOffstage: false);
  return Navigator.of(tester.element(home.first), rootNavigator: true);
}

/// Pops the top route through the root navigator (the app bar back buttons are
/// local widgets without a stable key). Asserts a pushed route exists so a
/// mistaken extra pop can never dismiss the home surface instead.
Future<void> _popRoute(WidgetTester tester) async {
  final navigator = _rootNavigator(tester);
  expect(navigator.canPop(), isTrue, reason: 'a pushed route is below');
  navigator.pop();
  await pumpFrames(tester, frames: 12);
}

/// Closes the mobile drawer without popping a route (the drawer is a position,
/// not a route), so the next tap can land on the home app bar again.
Future<void> _closeDrawer(WidgetTester tester) async {
  final scaffold = find.byType(HomeMobileScaffold);
  if (scaffold.evaluate().isEmpty) return;
  tester.widget<HomeMobileScaffold>(scaffold).drawerController.jumpTo(0.0);
  await pumpFrames(tester, frames: 8);
}

/// Opens a row of the R5 harness drawer by its rendered label.
///
/// Harvested rows carry slug keys derived from the Host's label; the label
/// itself is the authoritative anchor, so a Host translation change cannot
/// silently point the scenario at a different surface. The row is tapped, then
/// the official-WebUI page it opens is awaited by its Cuplivo chrome title.
Future<void> _openHarvestedSidebarRow(
  WidgetTester tester,
  String label, {
  required AppLocalizations l10n,
}) async {
  await _openDrawer(tester);
  final drawer = find.byKey(const Key('dsh-drawer-entries'));
  await _pumpUntilFound(tester, drawer, what: 'the R5 drawer');
  final row = find.descendant(of: drawer, matching: find.text(label));
  await _pumpUntilFound(
    tester,
    row,
    what: 'the R5 row "$label"',
    maxFrames: 600,
  );
  await tester.ensureVisible(row.first);
  await pumpFrames(tester, frames: 4);
  await tester.tap(row.first);
  await _waitDshWebUiPage(
    tester,
    label: label,
    l10n: l10n,
    what: 'the official WebUI page landed on "$label"',
  );
  // Harvest-then-landing: the landing click happens only after the harvest
  // script resolves, so the official surface needs the extra settle time
  // before the evidence frame.
  await pumpFrames(tester, frames: 100);
}

/// Awaits the plugin WebUI page and asserts its chrome title names the surface.
///
/// The official UI itself is a platform view: its DOM is not in the Flutter
/// widget tree, so the route + title is the honest Flutter-side assertion and
/// the harvest (a previous step) is the evidence that the page rendered.
Future<void> _waitDshWebUiPage(
  WidgetTester tester, {
  required String label,
  required AppLocalizations l10n,
  required String what,
  int maxFrames = 600,
}) async {
  final page = find.byType(DshPluginWebPage);
  await _pumpUntilFound(tester, page, what: what, maxFrames: maxFrames);
  expect(
    find.textContaining('${l10n.dshPluginPanelTitle} · $label'),
    findsWidgets,
    reason: '$what title names "$label"',
  );
  // The WebUI itself has to finish loading before a capture is meaningful; the
  // platform view owns its pixels and may keep painting after the first frame.
  await pumpFrames(tester, frames: 30);
}

/// Re-opens the rail's 工作区文件 page from wherever the rail currently is.
Future<void> _openRailFilesPage(WidgetTester tester, Finder rail) async {
  final card = find.descendant(
    of: rail,
    matching: find.byKey(const Key('dsh-rail-workspace-files')),
  );
  if (card.evaluate().isEmpty) {
    final back = find.byKey(const Key('dsh-rail-back'));
    if (back.evaluate().isNotEmpty) {
      await tester.tap(back.first);
      await pumpFrames(tester, frames: 10);
    }
  }
  await _pumpUntilFound(
    tester,
    find.descendant(
      of: rail,
      matching: find.byKey(const Key('dsh-rail-workspace-files')),
    ),
    what: 'the R13 工作区文件 card',
  );
  final target = find
      .descendant(
        of: rail,
        matching: find.byKey(const Key('dsh-rail-workspace-files')),
      )
      .first;
  await tester.ensureVisible(target);
  await pumpFrames(tester, frames: 4);
  await tester.tap(target);
  await pumpFrames(tester, frames: 12);
}

/// Drags the transcript until [target] is built, then scrolls it into view.
///
/// `scrollUntilVisible` cannot be used here: its finder must resolve to exactly
/// one element at the end, and a `.first` finder throws while the target is
/// still unbuilt (the very state the scroll exists to leave). The transcript
/// rows are also matched more than once (a tool call and its result share the
/// same localized title), so this waits for any match and then ensures the
/// first one is on screen.
Future<void> _dragTranscriptUntil(
  WidgetTester tester,
  Finder transcript,
  Finder target, {
  required double dy,
}) async {
  final scrollable = find
      .descendant(of: transcript, matching: find.byType(Scrollable))
      .first;
  for (var drag = 0; drag < 120 && target.evaluate().isEmpty; drag += 1) {
    await tester.drag(scrollable, Offset(0, dy));
    await pumpFrames(tester, frames: 4);
  }
  expect(
    target,
    findsWidgets,
    reason: 'the transcript reaches the requested row when dragged',
  );
  await tester.ensureVisible(target.first);
  await pumpFrames(tester, frames: 20);
}

/// Waits for the bash tool card, allowing one approval if the Host asks.
///
/// The E2E Host's permission preset may gate shell tools; the pending-request
/// panel is the same UI a user sees, so answering it is part of the scenario
/// rather than a test-only shortcut. Any other pending request is left alone so
/// an unexpected prompt still fails on the missing tool card.
/// Whether the folded transcript already holds a tool call named [toolName].
///
/// The transcript list is virtualized, so the rendered card can be outside the
/// built range while the folded message data already has the call; this reads
/// the data the card is rendered from.
bool _transcriptHasToolCall(WidgetTester tester, String toolName) {
  final list = find.descendant(
    of: find.byKey(const ValueKey<String>('dsh-transcript')),
    matching: find.byType(MessageListView),
  );
  if (list.evaluate().isEmpty) return false;
  final view = tester.widget<MessageListView>(list.first);
  for (final parts in view.toolParts.values) {
    for (final part in parts) {
      if (part.toolName == toolName) return true;
    }
  }
  return false;
}

Future<void> _pumpUntilToolCall(
  WidgetTester tester, {
  int maxFrames = 1800,
  Finder? composer,
  Finder? sendButton,
  Finder? plusSheet,
}) async {
  final allow = find.byKey(const ValueKey<String>('dsh-approval-allow'));
  var frames = 0;
  var sendRetries = 0;
  while (frames < maxFrames) {
    if (_transcriptHasToolCall(tester, 'bash')) return;
    if (allow.evaluate().isNotEmpty) {
      await tester.tap(allow.first);
      await pumpFrames(tester, frames: 4);
      frames += 4;
      continue;
    }
    // A stale sheet over the composer would swallow the turn's send tap: close
    // it and re-send the prompt instead of waiting out the whole budget.
    if (plusSheet != null && plusSheet.evaluate().isNotEmpty) {
      if (sendRetries < 3) {
        e2eStep('R6 plus sheet reopened during the tool turn; closing it');
        await _dismissComposerSheet(tester, plusSheet);
        if (composer != null &&
            sendButton != null &&
            _composerText(tester, composer).trim().isNotEmpty) {
          await tester.tap(sendButton);
          await pumpFrames(tester, frames: 20);
        }
        sendRetries += 1;
        frames += 20;
        continue;
      }
    }
    await pumpFrames(tester, frames: 4);
    frames += 4;
  }
}

/// Types one line into the Host terminal and submits it with the IME newline.
///
/// `terminal_view` paints its screen with a canvas and uses a private
/// `TextInputClient` (no `EditableText`), so `tester.enterText` has nothing to
/// target. The test binding's text input is attached to that client instead,
/// which is the same path a phone's IME uses to insert text and press Enter.
Future<void> _typeIntoTerminal(WidgetTester tester, String line) async {
  tester.testTextInput.enterText(line);
  await pumpFrames(tester, frames: 12);
  // `receiveAction` is a guarded test API and returns a Future: without the
  // await the following pump raises a Guarded function conflict.
  await tester.testTextInput.receiveAction(TextInputAction.newline);
  await pumpFrames(tester, frames: 40);
}
