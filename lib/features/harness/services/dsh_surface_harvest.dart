import 'dart:convert';

import 'package:flutter/foundation.dart';

/// One entry the official Web UI contributes to a global surface.
///
/// [label] is the user-visible text exactly as the official UI renders it in
/// the current locale; [kind] is the stable, language-neutral identity for
/// surfaces that expose one (the right rail's `data-sidebar-right-guide-entry`
/// attribute). Neither is a DSH API: both are read from the official DOM and
/// handed straight back to the landing scripts, so Cuplivo never has to know a
/// plugin name, id or label in advance.
@immutable
class DshSurfaceEntry {
  const DshSurfaceEntry({required this.label, this.kind});

  final String label;

  /// Page-type kind for right-rail cards (e.g. `bw-diff`); null for sidebar
  /// rows and settings sections, which only expose their label.
  final String? kind;

  @override
  bool operator ==(Object other) =>
      other is DshSurfaceEntry && other.label == label && other.kind == kind;

  @override
  int get hashCode => Object.hash(label, kind);

  @override
  String toString() => kind == null ? label : '$label [$kind]';
}

/// One harvest message from the official Web UI.
///
/// A message may report one, two or all three surfaces: the automatic harvest
/// reports the sidebar and the right rail, while the settings harvest (which has
/// to open the official settings dialog) reports the settings sections only.
/// `null` therefore means "this message says nothing about that surface", which
/// is what lets a later partial message merge into an earlier one instead of
/// erasing it.
@immutable
class DshSurfacePatch {
  const DshSurfacePatch({this.sidebar, this.rail, this.settings, this.v = 1});

  final List<DshSurfaceEntry>? sidebar;
  final List<DshSurfaceEntry>? rail;
  final List<DshSurfaceEntry>? settings;
  final int v;

  bool get isEmpty =>
      (sidebar == null || sidebar!.isEmpty) &&
      (rail == null || rail!.isEmpty) &&
      (settings == null || settings!.isEmpty);

  /// Parses the payload posted by [DshSurfaceHarvest.script] or
  /// [DshSurfaceHarvest.settingsScript].
  ///
  /// Tolerant by design: a page that never finished booting, a Host that
  /// changed its DOM, or a truncated message all degrade to `null` instead of
  /// throwing into the WebView channel.
  static DshSurfacePatch? parse(Object? payload) {
    final raw = payload is String ? payload.trim() : '';
    if (raw.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final version = decoded['v'];
    if (version is! int || version < 1) return null;
    final patch = DshSurfacePatch(
      v: version,
      sidebar: decoded.containsKey('sidebar')
          ? _entries(decoded['sidebar'])
          : null,
      rail: decoded.containsKey('rail') ? _entries(decoded['rail']) : null,
      settings: decoded.containsKey('settings')
          ? _entries(decoded['settings'])
          : null,
    );
    return patch.isEmpty ? null : patch;
  }

  static List<DshSurfaceEntry> _entries(Object? value) {
    if (value is! List) return const <DshSurfaceEntry>[];
    final seen = <String>{};
    final entries = <DshSurfaceEntry>[];
    for (final item in value) {
      String? label;
      String? kind;
      if (item is String) {
        label = item;
      } else if (item is Map) {
        final rawLabel = item['label'];
        if (rawLabel is String) label = rawLabel;
        final rawKind = item['kind'];
        if (rawKind is String && rawKind.trim().isNotEmpty) {
          kind = rawKind.trim();
        }
      }
      if (label == null) continue;
      final normalized = label.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (normalized.isEmpty || normalized.length > 80) continue;
      final entry = DshSurfaceEntry(label: normalized, kind: kind);
      if (seen.add('${entry.kind ?? ''}\u0000$normalized')) entries.add(entry);
    }
    return List<DshSurfaceEntry>.unmodifiable(entries);
  }
}

/// The surfaces the embedded official Web UI exposes to a third-party client.
///
/// DSH plugins contribute React slots (`sidebar.panellist`,
/// `sidebar.right.tab.guide`, `settings.section`, …) inside the server's
/// single-page app, and the Host RPC does not enumerate those contributions:
/// `pluginManager/listPlugins` carries package metadata only. The only source of
/// truth for "which entries exist and what are they called" is the official UI
/// itself, so Cuplivo reads it once per Web UI load and renders the resulting
/// labels natively. See `docs/cuplivo-dsh/plugin-compat.md` §4–§6 for the slot
/// and DOM-anchor evidence behind these recipes.
@immutable
class DshSurfaceSnapshot {
  const DshSurfaceSnapshot({
    required this.sidebar,
    required this.rail,
    required this.settings,
    required this.capturedAt,
  });

  static const DshSurfaceSnapshot empty = DshSurfaceSnapshot(
    sidebar: <DshSurfaceEntry>[],
    rail: <DshSurfaceEntry>[],
    settings: <DshSurfaceEntry>[],
    capturedAt: null,
  );

  /// Left-sidebar rows in official order, excluding brand/new-session/chrome
  /// rows. Example on a fresh 0.2.2-rc.1 Web UI with two plugins installed:
  /// `插件`, `搜索服务`, `自动化任务`. The official 更多 menu is not a row in the
  /// panel list (it is the sidebar's own `PanelMoreMenu`), so it is not here.
  final List<DshSurfaceEntry> sidebar;

  /// Right-rail guide cards in official order, with their page-type kinds.
  /// Example: `工作区文件 [files]`, `代码变更 [bw-diff]`, `新建终端 [terminal]`.
  final List<DshSurfaceEntry> rail;

  /// Settings dialog sections in official order, as the official UI labels them.
  /// DSH's own sections are filtered out by [DshSettingsSectionLabels]; what
  /// remains is what a plugin registered through `settings.section`.
  final List<DshSurfaceEntry> settings;

  /// When the harvest ran; null for [empty].
  final DateTime? capturedAt;

  bool get isEmpty => sidebar.isEmpty && rail.isEmpty && settings.isEmpty;

  /// Sidebar labels only, for callers that do not render kinds.
  List<String> get sidebarLabels =>
      List<String>.unmodifiable(sidebar.map((entry) => entry.label));

  /// Rail labels only, for callers that do not render kinds.
  List<String> get railLabels =>
      List<String>.unmodifiable(rail.map((entry) => entry.label));

  /// Settings sections contributed by plugins (DSH's own sections removed).
  List<DshSurfaceEntry> get pluginSettingsSections =>
      List<DshSurfaceEntry>.unmodifiable(
        settings.where(
          (entry) => !DshSettingsSectionLabels.isBuiltIn(entry.label),
        ),
      );

  /// Merges one harvest message into this snapshot.
  DshSurfaceSnapshot merge(DshSurfacePatch patch) => DshSurfaceSnapshot(
    sidebar: patch.sidebar ?? sidebar,
    rail: patch.rail ?? rail,
    settings: patch.settings ?? settings,
    capturedAt: DateTime.now(),
  );

  /// Parses one payload into an empty snapshot; kept for tests and for callers
  /// that only ever receive a single message.
  static DshSurfaceSnapshot parse(Object? payload) {
    final patch = DshSurfacePatch.parse(payload);
    if (patch == null) return empty;
    return empty.merge(patch);
  }
}

/// Recognizes DSH's own settings sections inside a harvested label list.
///
/// DSH registers its sections client-side and exposes no language-neutral id in
/// the DOM (`docs/cuplivo-dsh/plugin-compat.md` §6.2b), so the only way to tell
/// an official section from a plugin-contributed one is its rendered label. The
/// table below is the set of official section labels for the eight locales
/// 0.2.2-rc.1 ships (extracted from the `dsh-client-ui-settings-*` and
/// `dsh-client-ui-agent-preset` locale dictionaries), so classification stays
/// exact in every locale the official UI can render and plugin sections can
/// never be mistaken for built-ins.
///
/// A label that is not in the table is a plugin section; a future DSH release
/// that renames a built-in section would surface it as an extra tab (visible
/// duplication) rather than silently hiding a plugin's page.
abstract final class DshSettingsSectionLabels {
  /// Suite of official section labels, all locales.
  static const Set<String> builtIn = <String>{
    // general
    '通用设置', 'General', '一般', 'Général', 'Allgemein', 'Общие', 'Geral',
    // models
    '模型', 'Models', 'モデル', 'Modelos', 'Modèles', 'Modelle', 'Модели',
    // plugins
    '内置插件', 'Built-in plugins', '組み込みプラグイン', 'Complementos integrados',
    'Plugins intégrés', 'Integrierte Plugins', 'Встроенные плагины',
    'Plug-ins integrados',
    // agent presets
    'Agent 预设', 'Agent presets', 'エージェントプリセット',
    'Ajustes preestablecidos del agente', 'Préréglages d\'agent',
    'Agentenvoreinstellungen', 'Настройки агента',
    'Predefinições de agente',
    // account (only rendered while signed in)
    '账号与余额', 'Account', 'アカウント', 'Cuenta', 'Compte', 'Konto',
    'Аккаунт', 'Conta',
  };

  static bool isBuiltIn(String label) => builtIn.contains(label.trim());
}

/// Holds the most recent [DshSurfaceSnapshot] per remote authority.
///
/// In-memory only: the official UI is the source of truth, so a stale cache
/// surviving a restart would only delay the truth. Each Web UI load refreshes
/// the snapshot and notifies every listener (native R5/R7 lists and the extra
/// settings tabs rebuild from the same instance).
///
/// [shared] is the app-wide instance: the settings page lives on a different
/// route than the home screen, so the harvest has to land somewhere both can
/// read.
class DshSurfaceInventory extends ChangeNotifier {
  DshSurfaceInventory();

  /// The instance every DSH surface reads and writes in this app session.
  static final DshSurfaceInventory shared = DshSurfaceInventory();

  final Map<String, DshSurfaceSnapshot> _byAuthority =
      <String, DshSurfaceSnapshot>{};

  /// Last snapshot for [authority], or [DshSurfaceSnapshot.empty].
  DshSurfaceSnapshot snapshotFor(String authority) =>
      _byAuthority[authority] ?? DshSurfaceSnapshot.empty;

  /// Stores a fresh harvest payload posted by the official Web UI of [authority].
  ///
  /// Partial payloads merge: the settings harvest must not wipe the sidebar and
  /// rail snapshot an earlier page load produced.
  void accept(String authority, Object? payload) {
    final patch = DshSurfacePatch.parse(payload);
    if (patch == null) {
      // Stage-only payloads are the scripts' diagnostics: a harvest that could
      // not open the official dialog says why instead of leaving Cuplivo to
      // time out. Debug builds only; never logged in release and never parsed.
      if (kDebugMode && payload is String && payload.contains('"stage"')) {
        debugPrint(
          '[dsh-harvest] ${payload.length > 240 ? payload.substring(0, 240) : payload}',
        );
      }
      return;
    }
    final previous = _byAuthority[authority] ?? DshSurfaceSnapshot.empty;
    final next = previous.merge(patch);
    if (previous.capturedAt != null &&
        listEquals(previous.sidebar, next.sidebar) &&
        listEquals(previous.rail, next.rail) &&
        listEquals(previous.settings, next.settings)) {
      return;
    }
    _byAuthority[authority] = next;
    notifyListeners();
  }

  void clear(String authority) {
    if (_byAuthority.remove(authority) != null) notifyListeners();
  }
}

/// Scripts that read the official Web UI and scripts that land on one entry.
///
/// All scripts are self-contained async IIFEs: the WebView host runs them once
/// after a successful load (or as the landing script of a native row) and never
/// waits for them. A failed harvest or landing leaves the page usable — the
/// fallback is always "the user finishes by hand in the official UI".
///
/// The recipes follow `docs/cuplivo-dsh/plugin-compat.md` §6:
/// - sidebar rows are `nav button` elements that contain the
///   `[data-slot="sidebar.panellist"]` outlet (label = `aria-label`);
/// - the right rail expands via `[data-sidebar-right-expand]`, and its cards are
///   `[data-sidebar-right-guide-entry="<kind>"]` buttons;
/// - the settings dialog is `[role="dialog"][data-shortcut-modal="settings"]`,
///   opened through the `settings.launcher` menu item or the `settings.trigger`
///   button, and its nav rows are the `settings.section` labels.
abstract final class DshSurfaceHarvest {
  /// Channel name the WebView host registers by default (see `DshWebUiView`).
  static const String channelName = 'CuplivoHost';

  /// The DOM helpers every recipe shares.
  ///
  /// The official UI renders the sidebar and the right rail as *dialogs* at
  /// phone widths, and both are closed by default. A recipe therefore has to
  /// click the visible toggle first, wait for the drawer to slide in, and only
  /// then read or click its rows. The same helpers also drive the account menu
  /// that hosts the 设置 item at phone width, where the well-known
  /// `settings.trigger` button does not exist.
  static const String _domHelpers =
      '''
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const norm = (value) => String(value == null ? '' : value).replace(/\\s+/g, ' ').trim();
  const inView = (element) => {
    if (!element) return false;
    const rect = element.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0 &&
      rect.left >= 0 && rect.right <= window.innerWidth + 1;
  };
  const press = (element) => {
    const base = {
      bubbles: true, cancelable: true, composed: true,
      button: 0, pointerId: 1, pointerType: 'mouse', isPrimary: true,
    };
    element.dispatchEvent(new PointerEvent('pointerdown', Object.assign({}, base, { buttons: 1 })));
    element.dispatchEvent(new MouseEvent('mousedown', Object.assign({}, base, { buttons: 1 })));
    element.dispatchEvent(new PointerEvent('pointerup', Object.assign({}, base, { buttons: 0 })));
    element.dispatchEvent(new MouseEvent('mouseup', Object.assign({}, base, { buttons: 0 })));
    element.dispatchEvent(new MouseEvent('click', Object.assign({}, base, { buttons: 0 })));
  };
  const sidebarOpener = /open sidebar|展开侧边栏|打开侧边栏|打开側邊欄|展开側邊欄|サイドバーを開く|사이드바 열기|seitenleiste öffnen|ouvrir la barre latérale|открыть боковую панель|abrir barra lateral/i;
  const sidebarCollapse = /collapse sidebar|收起侧边栏|收起側邊欄|关闭侧边栏|关闭側邊欄|sidebar schließen|réduire la barre|свернуть боковую|ocultar barra|サイドバーを閉じる|사이드바 닫기/i;
  const railOpener = /open right sidebar|展开右侧边栏|打开右侧边栏|打开右側邊欄|右侧边栏|サイドバーを開く|오른쪽 사이드바 열기|rechte seitenleiste öffnen|ouvrir la barre latérale droite|открыть правую панель|abrir barra lateral derecha/i;
  const railCollapse = /collapse right sidebar|收起右侧边栏|收起右側邊欄|关闭右侧边栏|关闭右側邊欄|rechte seitenleiste schließen|réduire la barre latérale droite|свернуть правую панель|ocultar barra lateral derecha/i;
  const visibleButton = (pattern) =>
    [...document.querySelectorAll('button')].find((button) =>
      pattern.test(norm(button.getAttribute('aria-label'))) && inView(button));
  const settingsTrigger = () =>
    document.querySelector('[data-slot="sidebar.settings"] button[aria-haspopup="menu"]') ||
    document.querySelector('[data-slot="settings.launcher"] button[aria-haspopup="menu"]');
  const settingsDialog = () =>
    document.querySelector('[role="dialog"][data-shortcut-modal="settings"]');
  const navRows = () =>
    [...document.querySelectorAll('nav button')].filter((button) =>
      button.querySelector('[data-slot="sidebar.panellist"]'));
  const openSidebar = async () => {
    for (let attempt = 0; attempt < 40; attempt++) {
      const trigger = settingsTrigger();
      if (trigger && inView(trigger)) return true;
      const opener = visibleButton(sidebarOpener);
      if (opener) opener.click();
      await sleep(250);
    }
    const trigger = settingsTrigger();
    return !!trigger && inView(trigger);
  };
  const closeSidebar = () => {
    const collapse = visibleButton(sidebarCollapse);
    if (collapse) collapse.click();
    return !!collapse;
  };
  const railToggle = () =>
    document.querySelector('[data-sidebar-right-expand]') || visibleButton(railOpener);
  const post = (payload) => {
    try {
      window.flutter_inappwebview.callHandler('$channelName', JSON.stringify(payload));
    } catch (_) {}
  };
''';

  /// Reads the sidebar rows and the right-rail cards, then posts
  /// `{"v":1,"sidebar":[{"label":…}],"rail":[{"label":…,"kind":…}]}` on
  /// [channelName].
  ///
  /// Mobile-safe: at phone widths the official UI turns the sidebar and the
  /// right rail into dialogs, so the script clicks their visible toggles,
  /// waits for the drawer, reads it and closes it again. Chrome rows are
  /// excluded by construction because a sidebar row carries the
  /// `sidebar.panellist` outlet while the brand/session/footer chrome does not.
  static const String script =
      '''
(async () => {
$_domHelpers
  try {
  const sidebar = [];
  if (await openSidebar()) {
    for (const button of navRows()) {
      const label = norm(button.getAttribute('aria-label')) ||
        norm(button.textContent).split('\\n')[0];
      if (label && sidebar.indexOf(label) < 0) sidebar.push(label);
    }
    closeSidebar();
    await sleep(300);
  }
  const rail = [];
  for (let attempt = 0; attempt < 30 && !rail.length; attempt++) {
    const toggle = railToggle();
    if (!toggle) {
      await sleep(250);
      continue;
    }
    toggle.click();
    await sleep(700);
    for (const card of document.querySelectorAll('[data-sidebar-right-guide-entry]')) {
      const kind = norm(card.getAttribute('data-sidebar-right-guide-entry'));
      const label = norm(card.innerText).split('\\n')[0] ||
        norm(card.getAttribute('aria-label'));
      if (label) rail.push({ label: label, kind: kind || null });
    }
    if (!rail.length) {
      toggle.click();
      await sleep(300);
    }
  }
  if (rail.length) {
    const collapse = visibleButton(railCollapse);
    if (collapse) collapse.click();
  }
  post({ v: 1, sidebar: sidebar.map((label) => ({ label: label })), rail: rail });
  } catch (error) {
    post({ v: 1, stage: 'script-error' });
  }
})();
''';

  /// Opens the official settings dialog, reports its sections and (when
  /// [landLabel] is given) leaves it open on that section.
  ///
  /// This is a separate script on purpose: the automatic [script] must not pop
  /// the settings dialog on every page load, so Cuplivo runs this one only when
  /// the user asks for the official settings surface or opens a plugin section
  /// tab. Two recipes live here because DSH's settings entry differs by width:
  /// wide layouts have a `settings.trigger` button, while a phone width only
  /// has the account menu inside the sidebar drawer. The dialog's nav rows are
  /// the `settings.section` labels in both cases.
  static String settingsScript({String? landLabel}) =>
      '''
(async () => {
$_domHelpers
  try {
  const landLabel = ${jsonEncode(landLabel ?? '')};
  const postStage = (stage) => post({ v: 1, stage: stage });
  if (!(await openSidebar())) {
    postStage('no-settings-trigger');
    return;
  }
  const trigger = settingsTrigger();
  for (let attempt = 0; attempt < 40 && !settingsDialog(); attempt++) {
    trigger.click();
    await sleep(300);
    const item = [...document.querySelectorAll('[role="menuitem"]')].find((element) =>
      /^(设置|Settings|Preferences|設定|Einstellungen|Préférences|Paramètres|Configurações|Ajustes|Настройки|설정)\$/.test(norm(element.innerText)));
    if (item) press(item);
    await sleep(350);
  }
  const root = settingsDialog();
  if (!root) {
    postStage('no-settings-dialog');
    return;
  }
  await sleep(300);
  const sections = [];
  for (const button of root.querySelectorAll('nav button')) {
    const label = norm(button.textContent);
    if (label && sections.indexOf(label) < 0) sections.push(label);
  }
  if (landLabel) {
    const target = [...root.querySelectorAll('nav button')].find((button) =>
      norm(button.textContent) === landLabel);
    if (target) {
      press(target);
      await sleep(500);
    } else {
      postStage('no-land-section');
    }
  } else {
    const close = root.querySelector('[data-slot="settings.close"] button') ||
      [...root.querySelectorAll('button')].find((button) =>
        /^(Close|关闭|關閉|閉じる|닫기|Schließen|Fermer|Закрыть|Fechar|Cerrar)\$/.test(norm(button.innerText)));
    if (close) close.click();
    await sleep(400);
    closeSidebar();
  }
  post({ v: 1, settings: sections.map((label) => ({ label: label })) });
  } catch (error) {
    post({ v: 1, stage: 'settings-error' });
  }
})();
''';

  /// Landing script for a left-sidebar row: opens the sidebar drawer (or the
  /// sidebar dialog at phone width), clicks the row by its harvested label and
  /// lets the official UI close the drawer itself.
  static String sidebarLandingScript(String label) =>
      '''
(async () => {
$_domHelpers
  const target = ${jsonEncode(label)};
  for (let attempt = 0; attempt < 60; attempt++) {
    await openSidebar();
    const row = navRows().find((button) =>
      norm(button.getAttribute('aria-label')) === target ||
      norm(button.textContent).split('\\n')[0] === target);
    if (row) {
      press(row);
      await sleep(700);
      break;
    }
    await sleep(250);
  }
  closeSidebar();
})();
''';

  /// Landing script for the official 更多 row.
  ///
  /// 更多 is DSH's own `PanelMoreMenu` entry. Wide layouts register it through
  /// a `sidebar.panellist.actions` outlet; at phone width the same action is
  /// the one sidebar row that has no `sidebar.panellist` outlet at all, so the
  /// recipe clicks the localized label first and falls back to that structural
  /// shape without guessing a label.
  static const String moreMenuLandingScript =
      '''
(async () => {
$_domHelpers
  const moreLabels = /^(更多|More|その他|더 보기|Más|Plus|Mehr|Ещё|Mais)\$/;
  for (let attempt = 0; attempt < 60; attempt++) {
    await openSidebar();
    const rows = [...document.querySelectorAll('nav button')];
    const more = rows.find((button) =>
        moreLabels.test(norm(button.getAttribute('aria-label')) || norm(button.textContent).split('\\n')[0])) ||
      rows.find((button) => inView(button) && !button.querySelector('[data-slot="sidebar.panellist"]'));
    if (more) {
      press(more);
      await sleep(700);
      break;
    }
    await sleep(250);
  }
})();
''';

  /// Landing script for a right-rail card. Prefers the harvested page-type
  /// [kind] (language-neutral `data-sidebar-right-guide-entry` attribute) and
  /// falls back to the visible [label]; opens the rail first, which is a dialog
  /// at phone width.
  static String railLandingScript(String label, {String? kind}) =>
      '''
(async () => {
$_domHelpers
  const target = ${jsonEncode(label)};
  const kind = ${jsonEncode(kind ?? '')};
  let card = null;
  for (let attempt = 0; attempt < 40 && !card; attempt++) {
    const cards = [...document.querySelectorAll('[data-sidebar-right-guide-entry]')];
    if (!cards.length) {
      const toggle = railToggle();
      if (toggle) toggle.click();
      await sleep(700);
      continue;
    }
    card = (kind ? cards.find((element) =>
        norm(element.getAttribute('data-sidebar-right-guide-entry')) === kind) : null) ||
      cards.find((element) => norm(element.innerText).split('\\n')[0] === target);
    if (!card) await sleep(300);
  }
  if (card) press(card);
})();
''';
}
