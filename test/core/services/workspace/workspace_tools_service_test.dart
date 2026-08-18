import 'dart:io';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/workspace.dart';
import 'package:Cuplivo/core/providers/workspace_provider.dart';
import 'package:Cuplivo/core/services/workspace/workspace_execution_context.dart';
import 'package:Cuplivo/core/services/workspace/workspace_tools_service.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late WorkspaceProvider workspaces;
  late Workspace workspace;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cuplivo_tools_cwd_');
    PathProviderPlatform.instance = _FakePathProvider(temp.path);
    SharedPreferences.setMockInitialValues({});
    workspaces = WorkspaceProvider();
    await workspaces.init();
    workspace = workspaces.defaultWorkspace!;
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test(
    'filesystem paths resolve from the assistant working directory',
    () async {
      final host = workspaces.hostPathFor(workspace)!;
      await Directory('$host/project').create(recursive: true);
      await File('$host/project/note.txt').writeAsString('cwd-data');
      await File('$host/root.txt').writeAsString('root-data');
      final assistant = Assistant(
        id: 'a1',
        name: 'Assistant',
        workspaceEnabled: true,
        workspaceId: workspace.id,
        workspaceDefaultDirectories: {workspace.id: '/workspace/project'},
      );
      final executionContext = WorkspaceExecutionContext(
        workspace: workspace,
        workingDirectory: '/workspace/project',
      );

      final definitions = WorkspaceToolsService.buildToolDefinitions(
        assistant: assistant,
        workspaces: workspaces,
        supportsTools: true,
        executionContext: executionContext,
      );
      final reminder = WorkspaceToolsService.buildPromptReminder(
        assistant: assistant,
        workspaces: workspaces,
        executionContext: executionContext,
      );

      final relative = await WorkspaceToolsService.tryHandleToolCall(
        name: WorkspaceToolNames.read,
        args: const {'path': 'note.txt'},
        assistant: assistant,
        workspaces: workspaces,
        executionContext: executionContext,
      );
      final absolute = await WorkspaceToolsService.tryHandleToolCall(
        name: WorkspaceToolNames.read,
        args: const {'path': '/workspace/root.txt'},
        assistant: assistant,
        workspaces: workspaces,
      );

      expect(relative, contains('cwd-data'));
      expect(absolute, contains('root-data'));
      expect(definitions.first.toString(), contains('/workspace/project'));
      expect(
        reminder,
        contains('Current working directory: /workspace/project'),
      );
    },
  );

  test('conversation override wins and escaping paths are rejected', () async {
    final host = workspaces.hostPathFor(workspace)!;
    await Directory('$host/assistant').create(recursive: true);
    await Directory('$host/conversation').create(recursive: true);
    await File('$host/assistant/note.txt').writeAsString('assistant-data');
    await File(
      '$host/conversation/note.txt',
    ).writeAsString('conversation-data');
    final assistant = Assistant(
      id: 'a1',
      name: 'Assistant',
      workspaceEnabled: true,
      workspaceId: workspace.id,
      workspaceDefaultDirectories: {workspace.id: '/workspace/assistant'},
    );
    final conversation = Conversation(
      title: 'Conversation',
      workspaceDirectoryOverrides: {workspace.id: '/workspace/conversation'},
    );

    final result = await WorkspaceToolsService.tryHandleToolCall(
      name: WorkspaceToolNames.read,
      args: const {'path': 'note.txt'},
      assistant: assistant,
      conversation: conversation,
      workspaces: workspaces,
    );
    final escaped = await WorkspaceToolsService.tryHandleToolCall(
      name: WorkspaceToolNames.read,
      args: const {'path': '../../outside.txt'},
      assistant: assistant,
      conversation: conversation,
      workspaces: workspaces,
    );

    expect(result, contains('conversation-data'));
    expect(escaped, contains('invalid_path'));
  });
}
