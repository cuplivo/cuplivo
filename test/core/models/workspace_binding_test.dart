import 'package:Cuplivo/core/models/tool_permission_mode.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/workspace_binding.dart';

void main() {
  group('WorkspaceBinding', () {
    test('fromExtras reads feature-prefixed keys', () {
      final binding = WorkspaceBinding.fromExtras({
        WorkspaceBinding.keyId: 'ws-1',
        WorkspaceBinding.keyCwd: 'lib',
        WorkspaceBinding.keyToolsUsed: true,
        'workspace.allowAll': true,
        'other.flag': true,
      });
      expect(binding.workspaceId, 'ws-1');
      expect(binding.cwd, 'lib');
      expect(binding.toolsUsed, isTrue);
      expect(
        ToolPermissionMode.fromExtras(binding.applyTo({})),
        ToolPermissionMode.requestApproval,
      );
      expect(binding.isBound, isTrue);
    });

    test('applyTo writes binding keys without mutating the source', () {
      final extras = <String, dynamic>{'other.flag': true};
      final next = const WorkspaceBinding(
        workspaceId: 'ws-1',
        cwd: 'src',
        toolsUsed: true,
      ).applyTo(extras);

      expect(extras.containsKey(WorkspaceBinding.keyId), isFalse);
      expect(next[WorkspaceBinding.keyId], 'ws-1');
      expect(next[WorkspaceBinding.keyCwd], 'src');
      expect(next[WorkspaceBinding.keyToolsUsed], isTrue);
      expect(next.containsKey('workspace.allowAll'), isFalse);
      expect(next['other.flag'], isTrue);
    });

    test('applyTo removes keys when unbound', () {
      final extras = <String, dynamic>{
        WorkspaceBinding.keyId: 'ws-1',
        WorkspaceBinding.keyCwd: 'src',
        WorkspaceBinding.keyToolsUsed: true,
        'workspace.allowAll': true,
        'other.flag': true,
      };
      final next = const WorkspaceBinding().applyTo(extras);
      expect(next.containsKey(WorkspaceBinding.keyId), isFalse);
      expect(next.containsKey(WorkspaceBinding.keyCwd), isFalse);
      expect(next.containsKey(WorkspaceBinding.keyToolsUsed), isFalse);
      expect(next.containsKey('workspace.allowAll'), isFalse);
      expect(next['other.flag'], isTrue);
      expect(const WorkspaceBinding().isBound, isFalse);
    });

    test('extrasHaveWorkspace requires a live bound workspace', () {
      bool exists(String id) => id == 'ws-1';

      expect(
        WorkspaceBinding.extrasHaveWorkspace({
          WorkspaceBinding.keyId: 'ws-1',
        }, exists),
        isTrue,
      );
      expect(
        WorkspaceBinding.extrasHaveWorkspace({
          WorkspaceBinding.keyId: 'missing',
        }, exists),
        isFalse,
      );
      expect(WorkspaceBinding.extrasHaveWorkspace(const {}, exists), isFalse);
      expect(WorkspaceBinding.extrasHaveWorkspace(null, exists), isFalse);
    });
  });

  group('grants', () {
    test('withoutGrant removes exactly the grant keys', () {
      // The set is the one spelling of "this device approved": a copy, a fork and
      // the legacy import all read it, so it must not quietly grow (the local
      // directory path is not a grant) or shrink.
      final extras = <String, dynamic>{
        'other.flag': true,
        'workspace.id': 'ws-1',
        WorkspaceBinding.keyCwd: 'src',
        ...{
          for (final key in ToolPermissionMode.grantExtrasKeys) key: 'marker',
        },
      };

      final next = ToolPermissionMode.withoutGrant(extras);

      expect(
        next.keys,
        isNot(anyElement(isIn(ToolPermissionMode.grantExtrasKeys))),
      );
      expect(next['other.flag'], isTrue);
      expect(next['workspace.id'], 'ws-1');
      expect(next[WorkspaceBinding.keyCwd], 'src');
      // The source is not mutated.
      expect(extras.keys, containsAll(ToolPermissionMode.grantExtrasKeys));
    });
  });
}
