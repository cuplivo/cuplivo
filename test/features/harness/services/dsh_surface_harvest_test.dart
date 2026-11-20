import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/harness/services/dsh_surface_harvest.dart';

void main() {
  group('DshSurfaceSnapshot.parse', () {
    test('reads both surfaces from a harvest payload', () {
      final snapshot = DshSurfaceSnapshot.parse(
        jsonEncode(<String, Object?>{
          'v': 1,
          'sidebar': <String>['插件', '搜索服务', '自动化任务', '更多'],
          'rail': <String>['工作区文件', '代码变更', '新建终端', '更多工具'],
        }),
      );
      expect(snapshot.sidebar, <String>['插件', '搜索服务', '自动化任务', '更多']);
      expect(snapshot.rail, <String>['工作区文件', '代码变更', '新建终端', '更多工具']);
      expect(snapshot.capturedAt, isNotNull);
      expect(snapshot.isEmpty, isFalse);
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
          ).sidebar,
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
          'rail': <String>[],
        }),
      );
      expect(snapshot.sidebar, <String>['搜 索', '插件']);
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
        'sidebar': <String>['插件', '搜索服务'],
        'rail': <String>['代码变更'],
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
    test(
      'harvest script posts on the shared channel and reads both surfaces',
      () {
        expect(DshSurfaceHarvest.channelName, 'CuplivoHost');
        expect(DshSurfaceHarvest.script, contains('panelList'));
        expect(DshSurfaceHarvest.script, contains('打开右侧边栏'));
        expect(
          DshSurfaceHarvest.script,
          contains('post({ v: 1, sidebar: sidebar, rail: rail })'),
        );
      },
    );

    test('landing scripts carry the escaped label and the same surfaces', () {
      final sidebar = DshSurfaceHarvest.sidebarLandingScript('搜索服务');
      expect(sidebar, contains('"搜索服务"'));
      expect(sidebar, contains('panelList'));
      expect(
        DshSurfaceHarvest.railLandingScript('新建 worktree'),
        contains('"新建 worktree"'),
      );
    });
  });
}
