import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/utils/sandbox_path_resolver.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'dart:io';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AppDatabase database;
  late ChatService chatService;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('kelivo_temp_save_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SandboxPathResolver.debugSetDirs(
      docsDir: tempDir.path,
      supportDir: tempDir.path,
    );
    database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = ChatDatabaseRepository(database);
    chatService = ChatService(existingRepository: repository);
    addTearDown(chatService.close);
    await chatService.init();
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test(
    'persistTemporaryConversation replays cache into the repository',
    () async {
      final conversation = await chatService.createDraftConversation(
        title: 'tmp',
        temporary: true,
      );
      await chatService.addMessage(
        conversationId: conversation.id,
        role: 'user',
        content: 'hello',
      );
      await chatService.addMessage(
        conversationId: conversation.id,
        role: 'assistant',
        content: 'hi',
      );

      final saved = await chatService.persistTemporaryConversation(
        conversation.id,
        newTitle: 'Saved Title',
      );
      expect(saved, isTrue);
      expect(chatService.isTemporaryConversation(conversation.id), isFalse);

      final restored = chatService.getConversation(conversation.id);
      expect(restored!.title, 'Saved Title');
      // Messages survive a fresh load from the repository (not the cache).
      final messages = await chatService.repo.getMessageIds(conversation.id);
      expect(messages, hasLength(2));
    },
  );

  test('persistTemporaryConversation rejects non-temporary ids', () async {
    final conversation = await chatService.createConversation(title: 'n');
    final saved = await chatService.persistTemporaryConversation(
      conversation.id,
    );
    expect(saved, isFalse);
  });

  test('kept title is untouched when newTitle is null', () async {
    final conversation = await chatService.createDraftConversation(
      title: 'Renamed by user',
      temporary: true,
    );
    await chatService.addMessage(
      conversationId: conversation.id,
      role: 'user',
      content: 'x',
    );
    await chatService.persistTemporaryConversation(conversation.id);
    expect(
      chatService.getConversation(conversation.id)!.title,
      'Renamed by user',
    );
  });
}
