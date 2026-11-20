import 'package:Cuplivo/features/harness/pages/home/harness_surface_entries.dart';
import 'package:Cuplivo/features/harness/services/dsh_surface_harvest.dart';
import 'package:flutter_test/flutter_test.dart';

/// The harvest delivers opaque labels (and, for rail cards, a language-neutral
/// kind); these helpers turn them into stable row ids and drop the labels
/// Cuplivo already renders natively. Nothing here may rewrite a label: landing
/// scripts and e2e assertions match the remote's text.
void main() {
  group('dshSurfaceEntryId', () {
    test('slugs Latin labels and lowercases consistently', () {
      expect(dshSurfaceEntryId('Search service'), 'search-service');
      expect(dshSurfaceEntryId('  Search   service  '), 'search-service');
    });

    test('keeps CJK labels readable and stable', () {
      expect(dshSurfaceEntryId('搜索服务'), '搜索服务');
      expect(dshSurfaceEntryId('新建 worktree'), '新建-worktree');
      expect(dshSurfaceEntryId('Issue 与 PR'), 'issue-与-pr');
    });

    test(
      'strips punctuation, collapses separators and never returns empty',
      () {
        expect(dshSurfaceEntryId('代码变更 (beta)!'), '代码变更-beta');
        expect(dshSurfaceEntryId('…'), 'entry');
      },
    );
  });

  group('dshHarvestedEntries', () {
    const sidebar = <DshSurfaceEntry>[
      DshSurfaceEntry(label: '插件'),
      DshSurfaceEntry(label: '搜索服务'),
      DshSurfaceEntry(label: '自动化任务'),
    ];

    test('keeps the official order and the verbatim label text', () {
      final rows = dshHarvestedEntries(sidebar);
      expect([for (final row in rows) row.label], ['插件', '搜索服务', '自动化任务']);
      expect([for (final row in rows) row.id], ['插件', '搜索服务', '自动化任务']);
    });

    test('keeps the language-neutral rail kind', () {
      final rows = dshHarvestedEntries(const <DshSurfaceEntry>[
        DshSurfaceEntry(label: '代码变更', kind: 'bw-diff'),
        DshSurfaceEntry(label: 'Issue 与 PR', kind: 'pr'),
      ]);
      expect([for (final row in rows) row.kind], ['bw-diff', 'pr']);
    });

    test('drops built-in labels, empty labels and repeats', () {
      final rows = dshHarvestedEntries(
        const <DshSurfaceEntry>[
          DshSurfaceEntry(label: '工作区文件', kind: 'files'),
          DshSurfaceEntry(label: '  '),
          DshSurfaceEntry(label: '代码变更', kind: 'bw-diff'),
          DshSurfaceEntry(label: '代码变更', kind: 'bw-diff'),
          DshSurfaceEntry(label: '新建终端', kind: 'terminal'),
        ],
        excludedLabels: const <String>{'工作区文件', '新建终端'},
      );
      expect([for (final row in rows) row.label], ['代码变更']);
    });

    test('drops built-in cards by their language-neutral kind', () {
      // The same official card renders a different label per UI language, so
      // the built-in de-duplication must key on the kind when it has one.
      final rows = dshHarvestedEntries(
        const <DshSurfaceEntry>[
          DshSurfaceEntry(label: 'Workspace files', kind: 'files'),
          DshSurfaceEntry(label: 'Changes', kind: 'bw-diff'),
          DshSurfaceEntry(label: 'New terminal', kind: 'terminal'),
          DshSurfaceEntry(label: 'New worktree', kind: 'bw-worktree'),
          DshSurfaceEntry(label: 'Issues & PRs', kind: 'bw-forge'),
        ],
        excludedKinds: const <String>{'files', 'terminal'},
      );
      expect(
        [for (final row in rows) row.label],
        ['Changes', 'New worktree', 'Issues & PRs'],
      );
    });

    test('dedupes id collisions with a stable suffix', () {
      final rows = dshHarvestedEntries(const <DshSurfaceEntry>[
        DshSurfaceEntry(label: 'Search service'),
        DshSurfaceEntry(label: 'search-service'),
      ]);
      expect(
        [for (final row in rows) row.id],
        ['search-service', 'search-service-2'],
      );
    });

    test('nothing harvested means no rows', () {
      expect(dshHarvestedEntries(const <DshSurfaceEntry>[]), isEmpty);
    });
  });
}
