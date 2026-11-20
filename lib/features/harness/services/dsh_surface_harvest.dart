import 'dart:convert';

import 'package:flutter/foundation.dart';

/// The surfaces the embedded official Web UI exposes to a third-party client.
///
/// DSH plugins contribute React slots (`sidebar.panellist`,
/// `sidebar.right.pane.tab`, …) inside the server's single-page app, and the
/// Host RPC does not enumerate those contributions: `pluginManager/listPlugins`
/// carries package metadata only. The only source of truth for "which entries
/// exist and what are they called" is the official UI itself, so Cuplivo reads
/// it once per Web UI load and renders the resulting labels natively.
///
/// Nothing in this file names a plugin. Labels are opaque strings shown to the
/// user and handed back to the landing scripts, which click the same label in
/// the official UI — the contract is "read the surface, then open the same
/// entry by its own label", not "know that better-search exists".
@immutable
class DshSurfaceSnapshot {
  const DshSurfaceSnapshot({
    required this.sidebar,
    required this.rail,
    required this.capturedAt,
  });

  static const DshSurfaceSnapshot empty = DshSurfaceSnapshot(
    sidebar: <String>[],
    rail: <String>[],
    capturedAt: null,
  );

  /// Left sidebar rows in official order, excluding the brand/new-session/chrome
  /// rows. Example on a fresh 0.2.2-rc.1 Web UI with two plugins installed:
  /// `['插件', '搜索服务', '自动化任务', '更多']`.
  final List<String> sidebar;

  /// Right-rail entry cards in official order. Example:
  /// `['工作区文件', '代码变更', '新建终端', '新建 worktree', 'Issue 与 PR', '更多工具']`.
  final List<String> rail;

  /// When the harvest ran; null for [empty].
  final DateTime? capturedAt;

  bool get isEmpty => sidebar.isEmpty && rail.isEmpty;

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
    final sidebar = _labels(decoded['sidebar']);
    final rail = _labels(decoded['rail']);
    final version = decoded['v'];
    if (version is! int || version < 1) return empty;
    return DshSurfaceSnapshot(
      sidebar: sidebar,
      rail: rail,
      capturedAt: DateTime.now(),
    );
  }

  static List<String> _labels(Object? value) {
    if (value is! List) return const <String>[];
    final seen = <String>{};
    final labels = <String>[];
    for (final item in value) {
      if (item is! String) continue;
      final label = item.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (label.isEmpty || label.length > 80) continue;
      if (seen.add(label)) labels.add(label);
    }
    return List<String>.unmodifiable(labels);
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
abstract final class DshSurfaceHarvest {
  /// Channel name the WebView host registers by default (see `DshWebUiView`).
  static const String channelName = 'CuplivoHost';

  /// Reads the sidebar rows and the right-rail cards, then posts
  /// `{"v":1,"sidebar":[…],"rail":[…]}` on [channelName].
  ///
  /// Mobile-safe: the sidebar and the right rail are drawers at phone widths,
  /// so the script opens each one when it is not visible and closes it again
  /// after reading. Chrome rows are excluded by construction: sidebar rows must
  /// be `button[aria-label]` inside the panel list, and rail cards are the
  /// buttons that appear only after the rail opens (the toggle itself is
  /// already in the DOM).
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
  const findNav = () => document.querySelector('nav[class*="panelList"]');
  let nav = null;
  for (let i = 0; i < 60; i++) {
    nav = findNav();
    if (nav) break;
    await sleep(250);
  }
  let openedSidebar = false;
  if (!nav) {
    openedSidebar = click('展开侧边栏') || click('打开侧边栏') || click('打开导航栏');
    for (let i = 0; i < 20 && !nav; i++) {
      await sleep(250);
      nav = findNav();
    }
  }
  const sidebar = [];
  if (nav) {
    for (const button of nav.querySelectorAll('button[aria-label]')) {
      const label = norm(button.getAttribute('aria-label'));
      if (label && sidebar.indexOf(label) < 0) sidebar.push(label);
    }
  }
  if (openedSidebar) click('收起侧边栏');

  const rail = [];
  const railToggle = document.querySelector('[aria-label="打开右侧边栏"], [aria-label="展开／收起右侧边栏"]');
  if (railToggle) {
    const before = new Set();
    for (const button of document.querySelectorAll('button')) {
      const rect = button.getBoundingClientRect();
      if (rect.width > 0 && rect.height > 0) before.add(button);
    }
    railToggle.click();
    for (let attempt = 0; attempt < 24; attempt++) {
      await sleep(250);
      const fresh = [];
      for (const button of document.querySelectorAll('button')) {
        if (before.has(button)) continue;
        const rect = button.getBoundingClientRect();
        const label = norm(button.innerText).split('\\n')[0];
        if (!label || label.length > 40) continue;
        if (rect.width < 100 || rect.height < 28) continue;
        fresh.push(label);
      }
      if (fresh.length) {
        for (const label of fresh) if (rail.indexOf(label) < 0) rail.push(label);
        break;
      }
    }
    railToggle.click();
  }
  post({ v: 1, sidebar: sidebar, rail: rail });
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
  const findNav = () => document.querySelector('nav[class*="panelList"]');
  const row = () => {
    const nav = findNav();
    if (!nav) return null;
    for (const button of nav.querySelectorAll('button[aria-label]')) {
      if (norm(button.getAttribute('aria-label')) === target) return button;
    }
    return null;
  };
  let openedSidebar = false;
  for (let i = 0; i < 60; i++) {
    const nav = findNav();
    const match = row();
    if (match) { match.click(); break; }
    if (!nav && !openedSidebar) {
      for (const opener of ['展开侧边栏', '打开侧边栏', '打开导航栏']) {
        const button = document.querySelector('button[aria-label="' + opener + '"]');
        if (button) { button.click(); openedSidebar = true; break; }
      }
    }
    await sleep(250);
  }
  await sleep(400);
  const collapse = document.querySelector('button[aria-label="收起侧边栏"]');
  if (collapse) collapse.click();
})();
''';

  /// Landing script for a right-rail card: opens the rail, clicks the card by
  /// its harvested label, leaves the rail open on the card's page.
  static String railLandingScript(String label) =>
      '''
(async () => {
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const norm = (value) => String(value == null ? '' : value).replace(/\\s+/g, ' ').trim();
  const target = ${jsonEncode(label)};
  const toggle = document.querySelector('[aria-label="打开右侧边栏"], [aria-label="展开／收起右侧边栏"]');
  if (toggle) toggle.click();
  for (let i = 0; i < 60; i++) {
    await sleep(250);
    for (const button of document.querySelectorAll('button')) {
      const rect = button.getBoundingClientRect();
      const text = norm(button.innerText).split('\\n')[0];
      if (rect.width < 100 || rect.height < 28) continue;
      if (text === target || text.startsWith(target)) { button.click(); return; }
    }
  }
})();
''';
}
