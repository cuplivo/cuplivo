import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'dsh_surface_scripts.dart';

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
/// Thin forwarders: the recipe strings live in [DshSurfaceScripts] so that the
/// CI DOM-contract check can execute exactly what the app ships, without a
/// second copy drifting from the app's copy.
abstract final class DshSurfaceHarvest {
  /// Channel name the WebView host registers by default (see `DshWebUiView`).
  static const String channelName = DshSurfaceScripts.channelName;

  /// Reads both native surfaces and posts them on [channelName].
  static const String script = DshSurfaceScripts.harvest;

  /// Opens the official settings dialog and reports its sections; with
  /// [landLabel] it leaves the dialog open on that section.
  static String settingsScript({String? landLabel}) =>
      DshSurfaceScripts.settings(landLabel: landLabel);

  /// Lands on one left-sidebar row by its harvested [label].
  static String sidebarLandingScript(String label) =>
      DshSurfaceScripts.sidebarLanding(label);

  /// Lands on DSH's own 更多 entry.
  static const String moreMenuLandingScript = DshSurfaceScripts.moreMenuLanding;

  /// Lands on one right-rail card by [label], preferring the page [kind].
  static String railLandingScript(String label, {String? kind}) =>
      DshSurfaceScripts.railLanding(label, kind: kind);
}
