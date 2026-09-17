import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/features/home/controllers/message_render_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ChatMessage message(
    String id,
    String role, {
    String? groupId,
    int version = 0,
    bool streaming = false,
  }) => ChatMessage(
    id: id,
    role: role,
    content: id,
    conversationId: 'conversation',
    groupId: groupId,
    version: version,
    isStreaming: streaming,
  );

  test('projects versions, divider and latest assistant in one snapshot', () {
    final user = message('user', 'user');
    final first = message('a0', 'assistant', groupId: 'answer', version: 0);
    final selected = message('a2', 'assistant', groupId: 'answer', version: 2);
    final streaming = message('tail', 'assistant', streaming: true);

    final models = MessageRenderModelProjector.project(
      messages: [user, selected, streaming],
      byGroup: {
        'user': [user],
        'answer': [selected, first],
        'tail': [streaming],
      },
      versionSelections: const {'answer': 2},
      versionCounts: const {'answer': 2},
      contextDividerIndex: 1,
    );

    expect(models.map((model) => model.slotId), ['user', 'answer', 'tail']);
    expect(models[1].versions.map((item) => item.version), [0, 2]);
    expect(models[1].availableVersions, [0, 2]);
    expect(models[1].selectedVersion, 2);
    expect(models[1].selectedVersionIndex, 1);
    expect(models[1].showContextDivider, isTrue);
    expect(models[1].isLatestCompleteAssistant, isTrue);
    expect(models[2].isLatestCompleteAssistant, isFalse);
  });

  test('clamps stale selections without scanning from a row builder', () {
    final only = message('only', 'assistant');
    final models = MessageRenderModelProjector.project(
      messages: [only],
      byGroup: {
        'only': [only],
      },
      versionSelections: const {'only': 99},
      versionCounts: const {'only': 1},
      contextDividerIndex: -1,
    );

    expect(models.single.selectedVersionIndex, 0);
    expect(models.single.versionCount, 1);
  });

  test('uses available revisions for the display ordinal', () {
    final selected = message('a1', 'assistant', groupId: 'answer', version: 1);

    final models = MessageRenderModelProjector.project(
      messages: [selected],
      byGroup: {
        'answer': [selected],
      },
      versionSelections: const {'answer': 1},
      versionCounts: const {'answer': 2},
      contextDividerIndex: -1,
    );

    expect(models.single.versions, [selected]);
    expect(models.single.versionCount, 2);
    expect(models.single.selectedVersionIndex, 0);
  });
}
