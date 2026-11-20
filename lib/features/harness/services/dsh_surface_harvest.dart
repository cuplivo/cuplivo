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
  /// rows, which only expose their accessible label.
  final String? kind;

  @override
  bool operator ==(Object other) =>
      other is DshSurfaceEntry && other.label == label && other.kind == kind;

  @override
  int get hashCode => Object.hash(label, kind);

  @override
  String toString() => kind == null ? label : '$label [$kind]';
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
    required this.capturedAt,
  });

  static const DshSurfaceSnapshot empty = DshSurfaceSnapshot(
    sidebar: <DshSurfaceEntry>[],
    rail: <DshSurfaceEntry>[],
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

  /// When the harvest ran; null for [empty].
  final DateTime? capturedAt;

  bool get isEmpty => sidebar.isEmpty && rail.isEmpty;

  /// Sidebar labels only, for callers that do not render kinds.
  List<String> get sidebarLabels =>
      List<String>.unmodifiable(sidebar.map((entry) => entry.label));

  /// Rail labels only, for callers that do not render kinds.
  List<String> get railLabels =>
      List<String>.unmodifiable(rail.map((entry) => entry.label));

  /// Parses the payload posted by [DshSurfaceHarvest.script].
  ///
  /// Tolerant by design: a page that never finished booting, a Host that
  /// changed its DOM, or a truncated message all degrade to [empty] instead of
  /// throwing into the WebView channel.
  static DshSurfaceSnapshot parse(Object? payload) {
    final raw = payload is String ? payload.trim() : '';
    if (raw.isEmpty) return empty;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return empty;
    }
    if (decoded is! Map) return empty;
    final version = decoded['v'];
    if (version is! int || version < 1) return empty;
    final sidebar = _entries(decoded['sidebar']);
    final rail = _entries(decoded['rail']);
    return DshSurfaceSnapshot(
      sidebar: sidebar,
      rail: rail,
      capturedAt: DateTime.now(),
    );
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

/// Holds the most recent [DshSurfaceSnapshot] per remote authority.
///
/// In-memory only: the official UI is the source of truth, so a stale cache
/// surviving a restart would only delay the truth. Each Web UI load refreshes
/// the snapshot and notifies every listener (native R5/R7 lists rebuild).
class DshSurfaceInventory extends ChangeNotifier {
  final Map<String, DshSurfaceSnapshot> _byAuthority =
      <String, DshSurfaceSnapshot>{};

  /// Last snapshot for [authority], or [DshSurfaceSnapshot.empty].
  DshSurfaceSnapshot snapshotFor(String authority) =>
      _byAuthority[authority] ?? DshSurfaceSnapshot.empty;

  /// Stores a fresh harvest payload posted by the official Web UI of [authority].
  void accept(String authority, Object? payload) {
    final snapshot = DshSurfaceSnapshot.parse(payload);
    if (snapshot.isEmpty) return;
    final previous = _byAuthority[authority];
    if (previous != null &&
        listEquals(previous.sidebar, snapshot.sidebar) &&
        listEquals(previous.rail, snapshot.rail)) {
      return;
    }
    _byAuthority[authority] = snapshot;
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
/// - the settings dialog (not harvested yet) is `[data-shortcut-modal="settings"]`
///   and is reached through `[data-slot="settings.launcher"]`.
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
