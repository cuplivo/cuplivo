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

  group('DshSurfaceSnapshot settings', () {
    test('keeps only labels that DSH itself does not own', () {
      final snapshot = DshSurfaceSnapshot.parse(
        jsonEncode(<String, Object?>{
          'v': 1,
          'settings': <Object?>[
            <String, Object?>{'label': '通用设置'},
            <String, Object?>{'label': '模型'},
            <String, Object?>{'label': '内置插件'},
            <String, Object?>{'label': 'Agent 预设'},
            <String, Object?>{'label': '团队搜索设置'},
          ],
        }),
      );
      expect(snapshot.settings.length, 5);
      final plugins = snapshot.pluginSettingsSections;
      expect(plugins.map((e) => e.label), <String>['团队搜索设置']);
    });

    test('recognizes the official labels in every shipped locale', () {
      for (final label in <String>[
        'General',
        '模型',
        'Allgemein',
        'Встроенные плагины',
        'Ajustes preestablecidos del agente',
        'Conta',
      ]) {
        expect(
          DshSettingsSectionLabels.isBuiltIn(label),
          isTrue,
          reason: label,
        );
      }
      expect(DshSettingsSectionLabels.isBuiltIn('团队搜索设置'), isFalse);
    });

    test('a settings message alone is a valid snapshot', () {
      final snapshot = DshSurfaceSnapshot.parse(
        jsonEncode(<String, Object?>{
          'v': 1,
          'settings': <Object?>[
            <String, Object?>{'label': '团队搜索设置'},
          ],
        }),
      );
      expect(snapshot.isEmpty, isFalse);
      expect(snapshot.sidebar, isEmpty);
      expect(snapshot.rail, isEmpty);
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
      // A settings-only message must merge, not wipe the sidebar/rail snapshot.
      inventory.accept(
        'host-a',
        jsonEncode(<String, Object?>{
          'v': 1,
          'settings': <Object?>[
            <String, Object?>{'label': '团队搜索设置'},
          ],
        }),
      );
      expect(inventory.snapshotFor('host-a').sidebar.length, 2);
      expect(inventory.snapshotFor('host-a').pluginSettingsSections.length, 1);
      inventory.clear('host-a');
      expect(notifications, 4);
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

    test('the settings script reads the dialog and can land on a section', () {
      final script = DshSurfaceHarvest.settingsScript(landLabel: '团队搜索设置');
      expect(script, contains('data-shortcut-modal="settings"'));
      expect(script, contains('"团队搜索设置"'));
      expect(script, contains('settings.close'));
      expect(DshSurfaceHarvest.settingsScript(), isNot(contains('"团队搜索设置"')));
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
