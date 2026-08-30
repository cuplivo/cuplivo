import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';

/// Regression tests for the conversation model binding write outlet
/// (ADR-0045 "conversation model independence").
///
/// Bug shape: switching the model right after creating a new chat wrote the
/// empty draft to SQLite via `_saveConversation` (drafts are memory-only for
/// every other write path), materializing a bogus empty conversation in the
/// sidebar. The binding on a draft must stay in memory until the first
/// message promotes the draft.
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ChatService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cuplivo_binding_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    service = ChatService();
    await service.init();
  });

  tearDown(() async {
    await service.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'draft model switch stays in memory: no empty conversation persists',
    () async {
      final draft = await service.createDraftConversation(
        title: 'New Chat',
        assistantId: 'a1',
      );

      expect(
        service.repo.getAllCompleteConversationsSync(),
        isEmpty,
        reason: 'a brand-new draft must not be in the DB yet',
      );

      await service.setConversationModelBinding(
        conversationId: draft.id,
        providerKey: 'OpenAI',
        modelId: 'gpt-5',
      );

      // Binding applied in memory, not persisted.
      final draftNow = service.getConversation(draft.id);
      expect(draftNow?.chatModelProvider, 'OpenAI');
      expect(draftNow?.chatModelId, 'gpt-5');
      expect(
        service.repo.getAllCompleteConversationsSync(),
        isEmpty,
        reason: 'switching the model on an empty draft must not persist it',
      );
    },
  );

  test('binding rides the draft promotion on first message', () async {
    final draft = await service.createDraftConversation(
      title: 'New Chat',
      assistantId: 'a1',
    );
    await service.setConversationModelBinding(
      conversationId: draft.id,
      providerKey: 'Claude',
      modelId: 'claude-4',
    );

    await service.addMessage(
      conversationId: draft.id,
      role: 'user',
      content: 'hello',
    );

    final rows = service.repo.getAllCompleteConversationsSync();
    expect(rows, hasLength(1));
    final persisted = service.getConversation(draft.id);
    expect(persisted?.chatModelProvider, 'Claude');
    expect(persisted?.chatModelId, 'claude-4');
  });

  test('persisted conversations write the binding immediately', () async {
    final convo = await service.createConversation(assistantId: 'a1');
    await service.setConversationModelBinding(
      conversationId: convo.id,
      providerKey: 'Gemini',
      modelId: 'gemini-3',
    );

    final rows = service.repo.getAllCompleteConversationsSync();
    expect(rows, hasLength(1));
    expect(rows.first.chatModelProvider, 'Gemini');
    expect(rows.first.chatModelId, 'gemini-3');
  });
}
