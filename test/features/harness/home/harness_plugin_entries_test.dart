import 'package:Cuplivo/features/harness/pages/home/harness_plugin_entries.dart';
import 'package:Cuplivo/features/harness/state/dsh_gateway_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _betterSearch = '@ds-hu/dsh-better-search';
const _bwDiff = '@ds-hu/dsh-bw-diff';
const _bwWorktree = '@ds-hu/dsh-bw-worktree';
const _bwForge = '@ds-hu/dsh-bw-forge';

DshPluginEntry _plugin(
  String moduleName, {
  bool enabled = true,
  String? phase,
  String title = 'Plugin',
}) {
  return DshPluginEntry(
    id: moduleName,
    title: title,
    moduleName: moduleName,
    enabled: enabled,
    phase: phase,
  );
}

void main() {
  group('curated sidebar rows', () {
    test('nothing is mounted without a Host inventory entry', () {
      expect(
        dshPluginSidebarRows(plugins: const [], languageCode: 'zh'),
        isEmpty,
      );
    });

    test('mounts better-search as 搜索服务 with its slot order', () {
      final rows = dshPluginSidebarRows(
        plugins: [_plugin(_betterSearch)],
        languageCode: 'zh',
      );

      expect(rows, hasLength(1));
      expect(rows.single.id, 'plugin-better-search');
      expect(rows.single.order, 5);
      expect(rows.single.label, '搜索服务');
      expect(rows.single.landingLabels, <String>['搜索服务', 'Search services']);
    });

    test('follows the app language and falls back to English', () {
      List<DshPluginSidebarRow> rows(String languageCode) =>
          dshPluginSidebarRows(
            plugins: [_plugin(_betterSearch)],
            languageCode: languageCode,
          );

      expect(rows('en').single.label, 'Search services');
      // better-search ships zh + en only; its own resolver falls back to en.
      expect(rows('ja').single.label, 'Search services');
    });

    test('disabled and failed/unloading modules contribute nothing', () {
      for (final phase in <String?>['failed', 'unloading']) {
        final plugins = <DshPluginEntry>[
          _plugin(_betterSearch, enabled: false),
          _plugin(_betterSearch, phase: phase),
        ];
        expect(
          dshPluginSidebarRows(plugins: plugins, languageCode: 'zh'),
          isEmpty,
          reason: 'phase $phase must not mount a curated row',
        );
      }
      // One eligible inventory row is enough even with a disabled duplicate.
      expect(
        dshPluginSidebarRows(
          plugins: [
            _plugin(_betterSearch, enabled: false),
            _plugin(_betterSearch),
          ],
          languageCode: 'zh',
        ),
        hasLength(1),
      );
    });

    test('unknown modules are never invented', () {
      expect(
        dshPluginSidebarRows(
          plugins: [_plugin('@acme/dsh-unknown-panel')],
          languageCode: 'zh',
        ),
        isEmpty,
      );
    });

    test('rows are ordered by their official slot order', () {
      final rows = dshPluginSidebarRows(
        plugins: [_plugin(_betterSearch)],
        languageCode: 'zh',
      );
      expect(rows.map((row) => row.order), <int>[5]);
      expect(
        dshKnownPluginContributions
            .where((contribution) => contribution.moduleName == _betterSearch)
            .single
            .sidebarRows
            .single
            .entryId,
        'better-search',
      );
    });
  });

  group('curated rail cards', () {
    List<DshPluginEntry> allBetterWorkspaces() => [
      _plugin(_bwDiff),
      _plugin(_bwWorktree),
      _plugin(_bwForge),
    ];

    test('nothing is mounted without a Host inventory entry', () {
      expect(
        dshPluginRailCards(plugins: const [], languageCode: 'zh'),
        isEmpty,
      );
    });

    test('mounts the three cards in guide order with their own copy', () {
      final cards = dshPluginRailCards(
        plugins: allBetterWorkspaces(),
        languageCode: 'zh',
      );

      expect(cards.map((card) => card.kind), <String>[
        'bw-diff',
        'bw-worktree',
        'bw-forge',
      ]);
      expect(cards.map((card) => card.order), <int>[20, 30, 40]);
      expect(cards.map((card) => card.title), <String>[
        '代码变更',
        '新建 worktree',
        'Issue 与 PR',
      ]);
      expect(cards.first.description, '查看本会话的代码变更，并提交 / 推送 / 建 PR');
      expect(cards.first.icon, DshKnownPluginIcon.diff);
    });

    test('an English app language uses the plugin English dictionary', () {
      final cards = dshPluginRailCards(
        plugins: allBetterWorkspaces(),
        languageCode: 'en',
      );
      expect(cards.map((card) => card.title), <String>[
        'Changes',
        'New worktree',
        'Issues & PRs',
      ]);
      expect(cards.first.description, contains('commit, push, or open a PR'));
    });

    test('a plugin the inventory does not report is not mounted', () {
      final cards = dshPluginRailCards(
        plugins: [_plugin(_bwDiff)],
        languageCode: 'zh',
      );
      expect(cards.map((card) => card.kind), <String>['bw-diff']);
    });

    test('a disabled module contributes no card', () {
      expect(
        dshPluginRailCards(
          plugins: [
            _plugin(_bwDiff, enabled: false),
            _plugin(_bwWorktree, phase: 'failed'),
          ],
          languageCode: 'zh',
        ),
        isEmpty,
      );
    });
  });
}
