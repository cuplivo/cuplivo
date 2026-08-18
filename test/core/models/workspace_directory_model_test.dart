import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('assistant defaults round-trip and remain separate per workspace', () {
    final assistant = Assistant(
      id: 'a1',
      name: 'Assistant',
      workspaceDefaultDirectories: const {
        'workspace-a': '/workspace/a',
        'workspace-b': '/workspace/b',
      },
    );

    final restored = Assistant.fromJson(assistant.toJson());
    expect(restored.workspaceDefaultDirectories['workspace-a'], '/workspace/a');
    expect(restored.workspaceDefaultDirectories['workspace-b'], '/workspace/b');
    expect(
      restored
          .copyWith(
            workspaceDefaultDirectories: const {
              'workspace-a': '/workspace/other',
            },
          )
          .workspaceDefaultDirectories,
      {'workspace-a': '/workspace/other'},
    );
  });

  test('conversation overrides round-trip and missing keys stay absent', () {
    final conversation = Conversation(
      id: 'c1',
      title: 'Conversation',
      workspaceDirectoryOverrides: const {
        'workspace-a': '/workspace/session',
        'workspace-b': '/workspace',
      },
    );

    final restored = Conversation.fromJson(conversation.toJson());
    expect(restored.workspaceDirectoryOverrides, {
      'workspace-a': '/workspace/session',
      'workspace-b': '/workspace',
    });
    expect(
      restored.workspaceDirectoryOverrides.containsKey('workspace-c'),
      isFalse,
    );
  });

  test('legacy JSON defaults both maps to empty', () {
    final assistant = Assistant.fromJson({'id': 'a1', 'name': 'Assistant'});
    final now = DateTime.utc(2026).toIso8601String();
    final conversation = Conversation.fromJson({
      'id': 'c1',
      'title': 'Conversation',
      'createdAt': now,
      'updatedAt': now,
    });

    expect(assistant.workspaceDefaultDirectories, isEmpty);
    expect(conversation.workspaceDirectoryOverrides, isEmpty);
  });
}
