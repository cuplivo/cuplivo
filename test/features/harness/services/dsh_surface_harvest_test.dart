import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/harness/services/dsh_surface_harvest.dart';

void main() {
  group('DshSurfaceSnapshot.parse', () {
    test(
      'reads both surfaces, including rail kinds, from a harvest payload',
      () {
        final snapshot = DshSurfaceSnapshot.parse(
          jsonEncode(<String, Object?>{
            'v': 1,
            'sidebar': <Object?>[
              <String, Object?>{'label': '插件'},
              <String, Object?>{'label': '搜索服务'},
              <String, Object?>{'label': '自动化任务'},
            ],
            'rail': <Object?>[
              <String, Object?>{'label': '工作区文件', 'kind': 'files'},
              <String, Object?>{'label': '代码变更', 'kind': 'bw-diff'},
              <String, Object?>{'label': '新建终端', 'kind': 'terminal'},
            ],
          }),
        );
        expect(snapshot.sidebarLabels, <String>['插件', '搜索服务', '自动化任务']);
        expect(snapshot.railLabels, <String>['工作区文件', '代码变更', '新建终端']);
        expect(snapshot.rail[1].kind, 'bw-diff');
        expect(snapshot.sidebar.first.kind, isNull);
        expect(snapshot.capturedAt, isNotNull);
        expect(snapshot.isEmpty, isFalse);
      },
    );

    test('accepts plain label strings for older payloads', () {
      final snapshot = DshSurfaceSnapshot.parse(
        jsonEncode(<String, Object?>{
          'v': 1,
          'sidebar': <String>['插件'],
        }),
      );
      expect(snapshot.sidebarLabels, <String>['插件']);
      expect(snapshot.rail, isEmpty);
    });

    test(
      'degrades to empty on garbage, wrong version and non-string lists',
      () {
        expect(DshSurfaceSnapshot.parse(null).isEmpty, isTrue);
        expect(DshSurfaceSnapshot.parse('').isEmpty, isTrue);
        expect(DshSurfaceSnapshot.parse('not json').isEmpty, isTrue);
        expect(
          DshSurfaceSnapshot.parse(
            jsonEncode(<String, Object?>{'v': 2}),
          ).isEmpty,
          isTrue,
        );
        expect(
          DshSurfaceSnapshot.parse(
            jsonEncode(<String, Object?>{
              'v': 1,
              'sidebar': <Object?>[1, null, '插件'],
              'rail': 'nope',
            }),
          ).sidebarLabels,
          <String>['插件'],
        );
      },
    );

    test('collapses whitespace, drops blanks, dedupes and caps length', () {
      final long = 'x' * 200;
      final snapshot = DshSurfaceSnapshot.parse(
        jsonEncode(<String, Object?>{
          'v': 1,
          'sidebar': <String>['  搜  索 ', '', '搜 索', long, '插件'],
          'rail': <Object?>[
            <String, Object?>{'label': '代码变更', 'kind': 'bw-diff'},
            <String, Object?>{'label': '代码变更', 'kind': 'bw-diff'},
          ],
        }),
      );
      expect(snapshot.sidebarLabels, <String>['搜 索', '插件']);
      expect(snapshot.rail.length, 1);
    });
  });

  group('DshSurfaceInventory', () {
    test('notifies once per distinct snapshot per authority', () {
      final inventory = DshSurfaceInventory();
      var notifications = 0;
      inventory.addListener(() => notifications++);
      final payload = jsonEncode(<String, Object?>{
        'v': 1,
        'sidebar': <Object?>[
          <String, Object?>{'label': '插件'},
          <String, Object?>{'label': '搜索服务'},
        ],
        'rail': <Object?>[
          <String, Object?>{'label': '代码变更', 'kind': 'bw-diff'},
        ],
      });
      inventory.accept('host-a', payload);
      inventory.accept('host-a', payload);
      inventory.accept('host-b', payload);
      expect(notifications, 2);
      expect(inventory.snapshotFor('host-a').sidebar.length, 2);
      expect(inventory.snapshotFor('missing').isEmpty, isTrue);
      inventory.clear('host-a');
      expect(notifications, 3);
      expect(inventory.snapshotFor('host-a').isEmpty, isTrue);
    });
  });

  group('DshSurfaceHarvest scripts', () {
    test('harvest script uses the slot anchors and posts both surfaces', () {
      expect(DshSurfaceHarvest.channelName, 'CuplivoHost');
      expect(
        DshSurfaceHarvest.script,
        contains('data-slot="sidebar.panellist"'),
      );
      expect(
        DshSurfaceHarvest.script,
        contains('data-sidebar-right-guide-entry'),
      );
      expect(
        DshSurfaceHarvest.script,
        contains(
          'post({ v: 1, sidebar: sidebar.map((label) => ({ label: label })), rail: rail })',
        ),
      );
    });

    test('landing scripts carry the escaped label and the surface anchors', () {
      final sidebar = DshSurfaceHarvest.sidebarLandingScript('搜索服务');
      expect(sidebar, contains('"搜索服务"'));
      expect(sidebar, contains('data-slot="sidebar.panellist"'));
      final rail = DshSurfaceHarvest.railLandingScript(
        '新建 worktree',
        kind: 'bw-worktree',
      );
      expect(rail, contains('"新建 worktree"'));
      expect(rail, contains('"bw-worktree"'));
      expect(rail, contains('data-sidebar-right-guide-entry'));
    });
  });
}
