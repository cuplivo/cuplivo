import 'package:flutter/widgets.dart';

import 'package:Cuplivo/icons/lucide_adapter.dart';

import '../../state/dsh_gateway_models.dart';

/// The client-surface contributions of a known plugin.
///
/// DSH plugins register their UI at runtime from their **client half**: a left
/// sidebar row goes through `ctx.slots.inject('sidebar.panellist', ...)` and a
/// right-rail guide card through `ctx.sidebarRightTabs.register({... guide:
/// ...})`. The Host RPCs only expose the plugin inventory — module name,
/// enabled/phase, and `meta.title`/`description`/`icon` — never those slot
/// registrations (see `docs/cuplivo-dsh/plugin-compat.md` §4.4), so no remote
/// client can discover an entry without rendering the official WebUI.
///
/// Cuplivo therefore mounts the fixed entries of a small set of known plugins
/// natively from this curated table, gated by the Host plugin inventory: the
/// table carries the structural facts that live in the plugin package (slot id
/// or page-type kind, order, and the plugin's own label dictionary), the
/// inventory decides whether that plugin is installed and enabled, and a
/// successful WebUI harvest stays authoritative and replaces these entries
/// with the Host's live labels.
///
/// Adding a plugin: copy the registration's id/order/labels from the plugin's
/// client bundle. `@ds-hu/dsh-better-search` v0.5.0, for example, registers
/// `sidebar.panellist` id `better-search`, `order: 5` and
/// `label: () => t("panel")` with `panel` = 搜索服务 / Search services; the
/// better-workspaces modules register right-rail tab types with a `guide`
/// entry (`bw-diff` order 20, `bw-worktree` order 30, `bw-forge` order 40).
@immutable
class DshKnownPluginContribution {
  const DshKnownPluginContribution({
    required this.moduleName,
    this.sidebarRows = const <DshKnownPluginSidebarRow>[],
    this.railCards = const <DshKnownPluginRailCard>[],
  });

  /// The package module name exactly as `pluginInventory/list` reports it.
  final String moduleName;

  final List<DshKnownPluginSidebarRow> sidebarRows;

  final List<DshKnownPluginRailCard> railCards;
}

/// One left-sidebar row a known plugin registers in `sidebar.panellist`.
@immutable
class DshKnownPluginSidebarRow {
  const DshKnownPluginSidebarRow({
    required this.entryId,
    required this.order,
    required this.labels,
    required this.fallbackLabel,
    this.icon = DshKnownPluginIcon.generic,
  });

  /// The `sidebar.panellist` registration id (also the `main` panel key).
  final String entryId;

  /// The slot's order. DSH sorts the rows by it (插件 0, 自动化任务 10, 更多
  /// after every panel row).
  final int order;

  /// The labels the plugin itself ships, keyed by language code — exactly the
  /// strings its translation dictionary renders, so both the native row and
  /// the WebUI landing script stay correct in every language the plugin has.
  final Map<String, String> labels;

  /// English label for app languages the plugin does not translate (the
  /// plugin's own resolver falls back the same way).
  final String fallbackLabel;

  final DshKnownPluginIcon icon;
}

/// One right-rail guide card a known plugin registers from a tab definition.
@immutable
class DshKnownPluginRailCard {
  const DshKnownPluginRailCard({
    required this.kind,
    required this.order,
    required this.labels,
    required this.fallbackLabel,
    this.descriptions = const <String, String>{},
    this.fallbackDescription,
    this.icon = DshKnownPluginIcon.generic,
  });

  /// The page-type kind the definition registers (`bw-diff`), which is also
  /// the language-neutral `data-sidebar-right-guide-entry` DOM value the
  /// landing script clicks.
  final String kind;

  /// The guide entry's ascending order among every card.
  final int order;

  /// The card titles the plugin itself ships, keyed by language code.
  final Map<String, String> labels;

  /// English title for app languages the plugin does not translate.
  final String fallbackLabel;

  /// The subtitles the plugin itself ships, keyed by language code; the
  /// official guide draws them under the title.
  final Map<String, String> descriptions;

  /// English subtitle for app languages the plugin does not translate.
  final String? fallbackDescription;

  final DshKnownPluginIcon icon;
}

/// The glyph family a known entry asks the drawer or rail to draw.
///
/// Cuplivo draws its own icons (the plugin ships JSX artwork), so the table
/// names a family and [dshKnownPluginIconData] maps it to the app's icon set.
enum DshKnownPluginIcon { search, diff, worktree, forge, generic }

/// Maps a table icon family to the Lucide glyph the app draws.
IconData dshKnownPluginIconData(DshKnownPluginIcon icon) => switch (icon) {
  DshKnownPluginIcon.search => Lucide.Search,
  DshKnownPluginIcon.diff => Lucide.GitCompare,
  DshKnownPluginIcon.worktree => Lucide.GitBranch,
  DshKnownPluginIcon.forge => Lucide.GitPullRequest,
  DshKnownPluginIcon.generic => Lucide.Box,
};

/// The curated client-surface table.
///
/// Only plugins whose contribution Cuplivo can mount truthfully belong here:
/// an entry whose slot id/kind, order and labels are known from the plugin
/// package. A plugin that is absent or disabled contributes nothing; an
/// unknown plugin contributes nothing natively, and the harvest covers it.
const List<DshKnownPluginContribution>
dshKnownPluginContributions = <DshKnownPluginContribution>[
  DshKnownPluginContribution(
    moduleName: '@ds-hu/dsh-better-search',
    sidebarRows: <DshKnownPluginSidebarRow>[
      DshKnownPluginSidebarRow(
        entryId: 'better-search',
        order: 5,
        labels: <String, String>{'zh': '搜索服务', 'en': 'Search services'},
        fallbackLabel: 'Search services',
        icon: DshKnownPluginIcon.search,
      ),
    ],
  ),
  DshKnownPluginContribution(
    moduleName: '@ds-hu/dsh-bw-diff',
    railCards: <DshKnownPluginRailCard>[
      DshKnownPluginRailCard(
        kind: 'bw-diff',
        order: 20,
        labels: <String, String>{'zh': '代码变更', 'en': 'Changes'},
        fallbackLabel: 'Changes',
        descriptions: <String, String>{
          'zh': '查看本会话的代码变更，并提交 / 推送 / 建 PR',
          'en': "Review this session's changes - commit, push, or open a PR",
        },
        fallbackDescription:
            "Review this session's changes - commit, push, or open a PR",
        icon: DshKnownPluginIcon.diff,
      ),
    ],
  ),
  DshKnownPluginContribution(
    moduleName: '@ds-hu/dsh-bw-worktree',
    railCards: <DshKnownPluginRailCard>[
      DshKnownPluginRailCard(
        kind: 'bw-worktree',
        order: 30,
        labels: <String, String>{'zh': '新建 worktree', 'en': 'New worktree'},
        fallbackLabel: 'New worktree',
        descriptions: <String, String>{
          'zh': '从当前分支创建一个隔离的 worktree，并在新会话里继续',
          'en':
              'Cut an isolated worktree from the current branch and continue in a new session',
        },
        fallbackDescription:
            'Cut an isolated worktree from the current branch and continue in a new session',
        icon: DshKnownPluginIcon.worktree,
      ),
    ],
  ),
  DshKnownPluginContribution(
    moduleName: '@ds-hu/dsh-bw-forge',
    railCards: <DshKnownPluginRailCard>[
      DshKnownPluginRailCard(
        kind: 'bw-forge',
        order: 40,
        labels: <String, String>{'zh': 'Issue 与 PR', 'en': 'Issues & PRs'},
        fallbackLabel: 'Issues & PRs',
        descriptions: <String, String>{
          'zh': '浏览并引用本仓库的 issue 与 pull request',
          'en':
              "Browse and reference this repository's issues and pull requests",
        },
        fallbackDescription:
            "Browse and reference this repository's issues and pull requests",
        icon: DshKnownPluginIcon.forge,
      ),
    ],
  ),
];

/// One curated sidebar row resolved against the Host plugin inventory.
@immutable
class DshPluginSidebarRow {
  const DshPluginSidebarRow({
    required this.id,
    required this.order,
    required this.label,
    required this.landingLabels,
    required this.icon,
  });

  /// Stable widget-key suffix (`plugin-<slot id>`); never a display string.
  final String id;

  /// The slot order the row keeps among the DSH built-ins.
  final int order;

  /// The row's label in the app language.
  final String label;

  /// Every official label the plugin ships, for the landing script: the
  /// official WebUI may run in another language than the app.
  final List<String> landingLabels;

  final DshKnownPluginIcon icon;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshPluginSidebarRow &&
          other.id == id &&
          other.order == order &&
          other.label == label &&
          listEquals(other.landingLabels, landingLabels) &&
          other.icon == icon;

  @override
  int get hashCode =>
      Object.hash(id, order, label, Object.hashAll(landingLabels), icon);

  @override
  String toString() => 'DshPluginSidebarRow($id, $label)';
}

/// One curated right-rail card resolved against the Host plugin inventory.
@immutable
class DshPluginRailCard {
  const DshPluginRailCard({
    required this.kind,
    required this.order,
    required this.title,
    this.description,
    required this.icon,
  });

  /// The language-neutral page kind; also the widget-key suffix.
  final String kind;

  /// The guide entry's order among the rail cards.
  final int order;

  final String title;
  final String? description;
  final DshKnownPluginIcon icon;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshPluginRailCard &&
          other.kind == kind &&
          other.order == order &&
          other.title == title &&
          other.description == description &&
          other.icon == icon;

  @override
  int get hashCode => Object.hash(kind, order, title, description, icon);

  @override
  String toString() => 'DshPluginRailCard($kind, $title)';
}

/// The curated sidebar rows [plugins] contribute, ready to mount.
///
/// A plugin that is not listed, is disabled, or whose Loader fiber failed or
/// unloads contributes nothing (its client half never runs there).
/// [languageCode] picks the display label; the landing labels always carry the
/// plugin's full dictionary. The result is ordered by the slot order.
List<DshPluginSidebarRow> dshPluginSidebarRows({
  required Iterable<DshPluginEntry> plugins,
  required String languageCode,
}) {
  final available = _availableModuleNames(plugins);
  final language = languageCode.trim().toLowerCase();
  final rows = <DshPluginSidebarRow>[];
  for (final contribution in dshKnownPluginContributions) {
    if (!available.contains(contribution.moduleName)) continue;
    for (final row in contribution.sidebarRows) {
      rows.add(
        DshPluginSidebarRow(
          id: 'plugin-${row.entryId}',
          order: row.order,
          label: _labelFor(row.labels, row.fallbackLabel, language),
          landingLabels: _landingLabels(row.labels, row.fallbackLabel),
          icon: row.icon,
        ),
      );
    }
  }
  rows.sort((left, right) {
    final byOrder = left.order.compareTo(right.order);
    return byOrder != 0 ? byOrder : left.id.compareTo(right.id);
  });
  return List<DshPluginSidebarRow>.unmodifiable(rows);
}

/// The curated right-rail cards [plugins] contribute, ready to mount.
///
/// The same inventory gate and language rules as [dshPluginSidebarRows] apply.
/// The result is ordered by the guide entry's order.
List<DshPluginRailCard> dshPluginRailCards({
  required Iterable<DshPluginEntry> plugins,
  required String languageCode,
}) {
  final available = _availableModuleNames(plugins);
  final language = languageCode.trim().toLowerCase();
  final cards = <DshPluginRailCard>[];
  for (final contribution in dshKnownPluginContributions) {
    if (!available.contains(contribution.moduleName)) continue;
    for (final card in contribution.railCards) {
      cards.add(
        DshPluginRailCard(
          kind: card.kind,
          order: card.order,
          title: _labelFor(card.labels, card.fallbackLabel, language),
          description: _optionalLabelFor(
            card.descriptions,
            card.fallbackDescription,
            language,
          ),
          icon: card.icon,
        ),
      );
    }
  }
  cards.sort((left, right) {
    final byOrder = left.order.compareTo(right.order);
    return byOrder != 0 ? byOrder : left.kind.compareTo(right.kind);
  });
  return List<DshPluginRailCard>.unmodifiable(cards);
}

/// Module names the Host inventory reports as present, enabled and not
/// mid-unload. A module may appear through more than one inventory entry
/// (e.g. its bundle wrapper and the module itself), so a single eligible row
/// is enough.
Set<String> _availableModuleNames(Iterable<DshPluginEntry> plugins) {
  final available = <String>{};
  for (final plugin in plugins) {
    if (!plugin.enabled) continue;
    final phase = plugin.phase?.trim().toLowerCase();
    if (phase == 'failed' || phase == 'unloading') continue;
    final moduleName = plugin.moduleName.trim();
    if (moduleName.isEmpty) continue;
    available.add(moduleName);
  }
  return available;
}

String _labelFor(Map<String, String> labels, String fallback, String language) {
  final localized = labels[language]?.trim() ?? '';
  if (localized.isNotEmpty) return localized;
  final english = labels['en']?.trim() ?? '';
  if (english.isNotEmpty) return english;
  final trimmedFallback = fallback.trim();
  return trimmedFallback.isNotEmpty ? trimmedFallback : labels.values.first;
}

String? _optionalLabelFor(
  Map<String, String> labels,
  String? fallback,
  String language,
) {
  final localized = labels[language]?.trim() ?? '';
  if (localized.isNotEmpty) return localized;
  final english = labels['en']?.trim() ?? '';
  if (english.isNotEmpty) return english;
  final trimmedFallback = fallback?.trim() ?? '';
  return trimmedFallback.isEmpty ? null : trimmedFallback;
}

List<String> _landingLabels(Map<String, String> labels, String fallback) {
  final result = <String>[];
  for (final label in <String>[...labels.values, fallback]) {
    final trimmed = label.trim();
    if (trimmed.isEmpty || result.contains(trimmed)) continue;
    result.add(trimmed);
  }
  return List<String>.unmodifiable(result);
}
