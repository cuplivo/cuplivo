import 'dart:io';

import 'package:Cuplivo/core/services/workspace/workspace_execution_context.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeWorkspaceDirectory', () {
    test('stores root-relative and absolute input canonically', () {
      expect(normalizeWorkspaceDirectory('/workspace'), '/workspace');
      expect(
        normalizeWorkspaceDirectory('project/src'),
        '/workspace/project/src',
      );
      expect(
        normalizeWorkspaceDirectory('/workspace/project/./src/../test'),
        '/workspace/project/test',
      );
    });

    test('rejects empty, foreign absolute, backslash, and escaping input', () {
      for (final path in <String>[
        '',
        '/tmp/project',
        r'project\src',
        '../outside',
        'project/bad:',
        'project/trailing.',
      ]) {
        expect(
          () => normalizeWorkspaceDirectory(path),
          throwsA(isA<WorkspacePathException>()),
          reason: path,
        );
      }
    });
  });

  group('resolveWorkspaceGuestPath', () {
    test('normalizes dot segments inside the workspace', () {
      expect(
        resolveWorkspaceGuestPath(
          './lib/../test/a.dart',
          baseDirectory: '/workspace/project',
        ),
        '/workspace/project/test/a.dart',
      );
    });

    test('absolute workspace paths stay root-anchored', () {
      expect(
        resolveWorkspaceGuestPath(
          '/workspace/other',
          baseDirectory: '/workspace/project',
        ),
        '/workspace/other',
      );
    });
  });

  test(
    'conversation override wins, otherwise assistant default is inherited',
    () {
      final assistant = Assistant(
        id: 'a1',
        name: 'Assistant',
        workspaceDefaultDirectories: const {
          'a': '/workspace/assistant-a',
          'b': '/workspace/assistant-b',
        },
      );
      final conversation = Conversation(
        title: 'Conversation',
        workspaceDirectoryOverrides: const {'a': '/workspace/conversation-a'},
      );

      expect(
        effectiveWorkspaceDirectory(
          assistant: assistant,
          conversation: conversation,
          workspaceId: 'a',
        ),
        '/workspace/conversation-a',
      );
      expect(
        effectiveWorkspaceDirectory(
          assistant: assistant,
          conversation: conversation,
          workspaceId: 'b',
        ),
        '/workspace/assistant-b',
      );
      expect(
        effectiveWorkspaceDirectory(
          assistant: assistant,
          conversation: conversation,
          workspaceId: 'c',
        ),
        '/workspace',
      );
    },
  );

  test(
    'missing configured directory is created and recreated after deletion',
    () async {
      final root = await Directory.systemTemp.createTemp('cuplivo_cwd_');
      addTearDown(() => root.delete(recursive: true));
      final workspace = Workspace.createDefault();

      final hostPath = await ensureWorkspaceDirectoryAtHostRoot(
        workspace: workspace,
        hostRoot: root.path,
        workingDirectory: '/workspace/project/session',
      );
      expect(await Directory(hostPath).exists(), isTrue);
      await Directory(hostPath).delete(recursive: true);
      await ensureWorkspaceDirectoryAtHostRoot(
        workspace: workspace,
        hostRoot: root.path,
        workingDirectory: '/workspace/project/session',
      );
      expect(await Directory(hostPath).exists(), isTrue);
    },
  );

  test(
    'read-only workspace rejects a missing directory without fallback',
    () async {
      final root = await Directory.systemTemp.createTemp('cuplivo_cwd_ro_');
      addTearDown(() => root.delete(recursive: true));
      final workspace = Workspace.createDefault().copyWith(readOnly: true);

      expect(
        () => ensureWorkspaceDirectoryAtHostRoot(
          workspace: workspace,
          hostRoot: root.path,
          workingDirectory: '/workspace/missing',
        ),
        throwsA(isA<WorkspacePathException>()),
      );
    },
  );

  test('working directory rejects a symbolic-link escape', () async {
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('cuplivo_cwd_root_');
    final outside = await Directory.systemTemp.createTemp(
      'cuplivo_cwd_outside_',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
      if (await outside.exists()) await outside.delete(recursive: true);
    });
    await Link('${root.path}/escape').create(outside.path);

    await expectLater(
      ensureWorkspaceDirectoryAtHostRoot(
        workspace: Workspace.createDefault(),
        hostRoot: root.path,
        workingDirectory: '/workspace/escape/created-outside',
      ),
      throwsA(isA<WorkspacePathException>()),
    );
    expect(
      await Directory('${outside.path}/created-outside').exists(),
      isFalse,
    );
  });
}
