import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/features/assistant/pages/assistant_settings_page.dart';
import 'package:Cuplivo/features/harness/pages/home/harness_home_chrome.dart';
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

    await bootSeededApp(tester, binding);
    final l10n = _l10n(tester);

    // R1: drawer → 助手与群聊 → create menu, where the third owner kind is
    // DeepSeek Harness.
    await _openDrawer(tester);
    if (!realMode) {
      // Hermetic evidence starts with the untouched local drawer.
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
    await _pumpUntilFound(
      tester,
      confirmButton,
      what: 'the direct-connect form 确认 button (R2)',
    );
    final tabs = find.byKey(const Key('dsh-settings-tabs'));
    await _pumpUntilFound(
      tester,
      tabs,
      what: 'the four-tab assistant settings page (R2)',
    );
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
  }, timeout: const Timeout(Duration(minutes: 10)));
}

const String _dshUrl = String.fromEnvironment('E2E_DSH_URL');
const String _dshToken = String.fromEnvironment('E2E_DSH_TOKEN');

/// A short prompt the E2E host's temporary key can answer inside the emulator
/// budget (`docs/cuplivo-dsh/e2e-scenario.md`).
const String _prompt = '你好，请用一句话介绍你自己';

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
  _expectSettingsTabs(tester, l10n);
  await pumpFrames(tester, frames: 20);
  await capture(tester, binding, 'r2_settings_connection');

  // Back to the owner list, then to the home surface (settings page → home).
  await _popRoute(tester);
  await _popRoute(tester);
  await _popRoute(tester);
  expect(
    _rootNavigator(tester).canPop(),
    isFalse,
    reason: 'the scenario is back on the home surface',
  );
  await pumpFrames(tester, frames: 20);

  // R5: the drawer now lists the remote owner; tapping it enters harness mode.
  await _openDrawer(tester);
  final ownerRow = find.byKey(const Key('dsh-owner-row'));
  await _pumpUntilFound(
    tester,
    ownerRow,
    what: 'the DeepSeek Harness owner row in the drawer (R5)',
  );
  await tester.ensureVisible(ownerRow);
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
  await capture(tester, binding, 'r6_chat');

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
  await capture(tester, binding, 'r7_right_rail');

  // Close the rail through its own header action, then walk to the remote's
  // settings page from the harness drawer (更多 → DSH 设置).
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

  await _openDrawer(tester);
  final moreEntry = find.descendant(
    of: find.byKey(const Key('dsh-drawer-entries')),
    matching: find.byKey(const Key('dsh-entry-more')),
  );
  await _pumpUntilFound(
    tester,
    moreEntry,
    what: 'the 更多 row of the harness drawer (R5)',
  );
  await tester.ensureVisible(moreEntry.first);
  await pumpFrames(tester, frames: 4);
  await tester.tap(moreEntry.first);
  final moreSettings = find.byKey(const Key('dsh-more-settings'));
  await _pumpUntilFound(
    tester,
    moreSettings,
    what: 'the DSH settings row of the 更多 menu',
  );
  await tester.tap(moreSettings.first);

  final settingsTabs = find.byKey(const Key('dsh-settings-tabs'));
  await _pumpUntilFound(
    tester,
    settingsTabs,
    what: 'the DSH assistant settings page',
  );
  final modelsTab = find.byKey(const Key('dsh-models-tab'));
  await _pumpUntilFound(tester, modelsTab, what: 'the 模型 tab (R9)');
  await tester.ensureVisible(modelsTab);
  await tester.tap(modelsTab);

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
  await capture(tester, binding, 'r9_models');

  // R10: the add-provider list, opened by the search bar's + action. The
  // models slice owns `dsh-models-add-provider`; the icon inside the search bar
  // is the fallback until that key lands.
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
  await capture(tester, binding, 'r10_add_provider');

  // R11: the custom provider detail, with the credential/base-URL fields.
  final customPick = find.byKey(const Key('dsh-provider-pick-custom'));
  await _pumpUntilFound(
    tester,
    customPick,
    what: 'the 自定义提供商 row of the add-provider list (R11)',
  );
  await tester.tap(customPick);
  // R11 has two honest shapes in this build: the editing form once the
  // provider-settings adapter is wired, and the read-only page that states the
  // adapter is missing. The scenario accepts either and proves it is the
  // provider detail page in both.
  final providerApiKey = find.byKey(const Key('dsh-provider-detail-api-key'));
  final providerId = find.byKey(const Key('dsh-provider-detail-id'));
  final settingsUnavailable = find.text(l10n.dshModelsSettingsUnavailableTitle);
  await pumpUntil(
    tester,
    () =>
        providerApiKey.evaluate().isNotEmpty ||
        providerId.evaluate().isNotEmpty ||
        settingsUnavailable.evaluate().isNotEmpty,
    maxFrames: 300,
  );
  expect(
    providerApiKey.evaluate().isNotEmpty ||
        providerId.evaluate().isNotEmpty ||
        settingsUnavailable.evaluate().isNotEmpty,
    isTrue,
    reason: 'the custom provider detail page (R11)',
  );
  expect(
    find.text(l10n.dshProviderDetailCustomProviderTitle),
    findsWidgets,
    reason: 'R11 custom provider detail title',
  );
  await pumpFrames(tester, frames: 20);
  await capture(tester, binding, 'r11_provider_detail');

  expect(tester.takeException(), isNull);
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
  await capture(tester, binding, 'hermetic_create_form');

  expect(tester.takeException(), isNull);
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

void _expectSettingsTabs(WidgetTester tester, AppLocalizations l10n) {
  final tabs = find.byKey(const Key('dsh-settings-tabs'));
  expect(tabs, findsOneWidget, reason: 'the assistant settings tab strip (R2)');
  for (final label in <String>[
    l10n.dshTabConnection,
    l10n.dshTabGeneral,
    l10n.dshTabModels,
    l10n.dshTabContent,
  ]) {
    expect(
      find.descendant(of: tabs, matching: find.text(label)),
      findsWidgets,
      reason: 'R2 tab $label',
    );
  }
}

void _expectDrawerSections(WidgetTester tester, Finder drawerEntries) {
  for (final key in <String>[
    'dsh-entry-plugins',
    'dsh-entry-automations',
    'dsh-entry-more',
  ]) {
    expect(
      find.descendant(of: drawerEntries, matching: find.byKey(Key(key))),
      findsOneWidget,
      reason: 'R5 drawer entry $key',
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
  return Navigator.of(tester.element(find.byType(HomeMobileScaffold)));
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
