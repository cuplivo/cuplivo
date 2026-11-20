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
    if (patch == null) return;
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

  /// Reads the sidebar rows and the right-rail cards, then posts
  /// `{"v":1,"sidebar":[{"label":…}],"rail":[{"label":…,"kind":…}]}` on
  /// [channelName].
  ///
  /// Mobile-safe: the sidebar and the right rail are drawers at phone widths,
  /// so the script opens each one when it is not visible and closes it again
  /// after reading. Chrome rows are excluded by construction.
  static const String script =
      '''
(async () => {
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const norm = (value) => String(value == null ? '' : value).replace(/\\s+/g, ' ').trim();
  const post = (payload) => {
    try {
      window.flutter_inappwebview.callHandler('$channelName', JSON.stringify(payload));
    } catch (_) {}
  };
  const click = (label) => {
    const button = document.querySelector('button[aria-label="' + label + '"]');
    if (button) { button.click(); return true; }
    return false;
  };
  const nav = () => document.querySelector('nav');
  const rows = () => {
    const root = nav();
    if (!root) return [];
    return [...root.querySelectorAll('button')]
      .filter((button) => button.querySelector('[data-slot="sidebar.panellist"]'));
  };
  let root = null;
  for (let i = 0; i < 60; i++) {
    root = nav();
    if (root) break;
    await sleep(250);
  }
  let openedSidebar = false;
  if (!rows().length) {
    openedSidebar = click('展开侧边栏') || click('打开侧边栏') || click('打开导航栏');
    for (let i = 0; i < 24 && !rows().length; i++) await sleep(250);
  }
  const sidebar = [];
  for (const button of rows()) {
    const label = norm(button.getAttribute('aria-label')) || norm(button.textContent).split('\\n')[0];
    if (label && sidebar.indexOf(label) < 0) sidebar.push(label);
  }
  if (openedSidebar) click('收起侧边栏');

  const rail = [];
  const railToggle = document.querySelector('[data-sidebar-right-expand]')
    || document.querySelector('[aria-label="打开右侧边栏"], [aria-label="展开／收起右侧边栏"]');
  if (railToggle) {
    railToggle.click();
    for (let attempt = 0; attempt < 24; attempt++) {
      await sleep(250);
      const cards = [...document.querySelectorAll('[data-sidebar-right-guide-entry]')];
      if (cards.length) {
        for (const card of cards) {
          const kind = norm(card.getAttribute('data-sidebar-right-guide-entry'));
          const label = norm(card.innerText).split('\\n')[0] || norm(card.getAttribute('aria-label'));
          if (!label) continue;
          rail.push({ label: label, kind: kind || null });
        }
        break;
      }
    }
    railToggle.click();
  }
  post({ v: 1, sidebar: sidebar.map((label) => ({ label: label })), rail: rail });
})();
''';

  /// Opens the official settings dialog, reports its sections and (when
  /// [landLabel] is given) leaves it open on that section.
  ///
  /// This is a separate script on purpose: the automatic [script] must not pop
  /// the settings dialog on every page load, so Cuplivo runs this one only when
  /// the user asks for the official settings surface or opens a plugin section
  /// tab. The dialog is closed again when nothing has to be landed on, so a
  /// harvest does not disturb the page the user is looking at.
  static String settingsScript({String? landLabel}) =>
      '''
(async () => {
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const norm = (value) => String(value == null ? '' : value).replace(/\\s+/g, ' ').trim();
  const landLabel = ${jsonEncode(landLabel ?? '')};
  const post = (payload) => {
    try {
      window.flutter_inappwebview.callHandler('$channelName', JSON.stringify(payload));
    } catch (_) {}
  };
  const dialog = () => document.querySelector('[role="dialog"][data-shortcut-modal="settings"]');
  const clickLabelled = (labels) => {
    for (const label of labels) {
      const button = document.querySelector('button[aria-label="' + label + '"]');
      if (button) { button.click(); return true; }
    }
    return false;
  };
  const openDialog = () => {
    if (dialog()) return true;
    const launcher = document.querySelector('[data-slot="settings.launcher"] button[aria-haspopup="menu"]');
    if (launcher) { launcher.click(); return true; }
    const trigger = document.querySelector('[data-slot="settings.trigger"] button[aria-haspopup="dialog"]')
      || document.querySelector('[data-slot="sidebar.settings"] button[aria-haspopup="dialog"]');
    if (trigger) { trigger.click(); return true; }
    // Mobile: the drawer may be closed, so open it and use the 设置 row.
    if (clickLabelled(['设置', 'Settings'])) return true;
    if (clickLabelled(['展开侧边栏', '打开侧边栏', '打开导航栏', 'Open sidebar'])) {
      return true;
    }
    return false;
  };
  for (let attempt = 0; attempt < 40 && !dialog(); attempt++) {
    openDialog();
    await sleep(250);
    if (attempt === 12) {
      // The launcher menu may still be open from the first click; pick 设置.
      const items = [...document.querySelectorAll('[role="menuitem"], button')];
      const settings = items.find((el) => norm(el.innerText) === '设置' || norm(el.innerText) === 'Settings');
      if (settings) settings.click();
    }
  }
  const root = dialog();
  if (!root) return;
  await sleep(200);
  const sections = [];
  for (const button of root.querySelectorAll('nav button')) {
    const label = norm(button.textContent);
    if (label && sections.indexOf(label) < 0) sections.push(label);
  }
  if (landLabel) {
    const target = [...root.querySelectorAll('nav button')].find((b) => norm(b.textContent) === landLabel);
    if (target) {
      target.click();
      await sleep(300);
    }
  } else {
    const close = document.querySelector('[data-slot="settings.close"] button')
      || root.querySelector('button[aria-label="关闭"], button[aria-label="Close"]');
    if (close) close.click();
  }
  post({ v: 1, settings: sections.map((label) => ({ label: label })) });
})();
''';

  /// Landing script for a left-sidebar row: opens the sidebar drawer when the
  /// page is narrow, clicks the row by its harvested label, closes the drawer.
  static String sidebarLandingScript(String label) =>
      '''
(async () => {
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const norm = (value) => String(value == null ? '' : value).replace(/\\s+/g, ' ').trim();
  const target = ${jsonEncode(label)};
  const rows = () => {
    const root = document.querySelector('nav');
    if (!root) return [];
    return [...root.querySelectorAll('button')]
      .filter((button) => button.querySelector('[data-slot="sidebar.panellist"]'));
  };
  const match = () => rows().find((button) =>
    norm(button.getAttribute('aria-label')) === target ||
    norm(button.textContent).split('\\n')[0] === target);
  let openedSidebar = false;
  for (let i = 0; i < 60; i++) {
    const hit = match();
    if (hit) { hit.click(); break; }
    if (!openedSidebar) {
      for (const opener of ['展开侧边栏', '打开侧边栏', '打开导航栏']) {
        const button = document.querySelector('button[aria-label="' + opener + '"]');
        if (button) { button.click(); openedSidebar = true; break; }
      }
    }
    await sleep(250);
  }
  await sleep(500);
  const collapse = document.querySelector('button[aria-label="收起侧边栏"]');
  if (collapse) collapse.click();
})();
''';

  /// Landing script for the official 更多 menu.
  ///
  /// 更多 is not a panel-list row (it is the sidebar's own `PanelMoreMenu`, a
  /// `sidebar.panellist.actions` registrant), so it is not part of the harvest;
  /// Cuplivo keeps one built-in row for it and opens the menu in the official
  /// Web UI. The trigger lives inside the `sidebar.panellist.actions` outlet.
  static const String moreMenuLandingScript = '''
(async () => {
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const trigger = () => {
    const outlet = document.querySelector('[data-slot="sidebar.panellist.actions"]');
    return outlet ? (outlet.closest('button') || outlet.querySelector('button')) : null;
  };
  let openedSidebar = false;
  for (let i = 0; i < 60; i++) {
    const button = trigger();
    if (button) { button.click(); return; }
    if (!openedSidebar) {
      for (const opener of ['展开侧边栏', '打开侧边栏', '打开导航栏']) {
        const candidate = document.querySelector('button[aria-label="' + opener + '"]');
        if (candidate) { candidate.click(); openedSidebar = true; break; }
      }
    }
    await sleep(250);
  }
})();
''';

  /// Landing script for a right-rail card. Prefers the harvested page-type
  /// [kind] (language-neutral `data-sidebar-right-guide-entry` attribute) and
  /// falls back to the visible [label].
  static String railLandingScript(String label, {String? kind}) =>
      '''
(async () => {
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const norm = (value) => String(value == null ? '' : value).replace(/\\s+/g, ' ').trim();
  const target = ${jsonEncode(label)};
  const kind = ${jsonEncode(kind ?? '')};
  const expand = document.querySelector('[data-sidebar-right-expand]')
    || document.querySelector('[aria-label="打开右侧边栏"], [aria-label="展开／收起右侧边栏"]');
  if (expand) expand.click();
  for (let i = 0; i < 60; i++) {
    await sleep(250);
    if (kind) {
      const card = document.querySelector('[data-sidebar-right-guide-entry="' + kind + '"]');
      if (card) { card.click(); return; }
    }
    for (const button of document.querySelectorAll('button')) {
      const text = norm(button.innerText).split('\\n')[0];
      const rect = button.getBoundingClientRect();
      if (rect.width < 80 || rect.height < 24) continue;
      if (text === target) { button.click(); return; }
    }
  }
})();
''';
}
