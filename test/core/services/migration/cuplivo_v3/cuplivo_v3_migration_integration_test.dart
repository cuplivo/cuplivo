import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_data.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/models/message_part.dart';
import 'package:Cuplivo/core/services/migration/cuplivo_v3/cuplivo_v3_reader.dart';
import 'package:Cuplivo/utils/sandbox_path_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'cuplivo_v3_reader_test.dart' show V3FixtureBuilder;

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

  late Directory root;
  late V3FixtureBuilder fixture;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cuplivo-v3-restore');
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    await SandboxPathResolver.init();
    fixture = V3FixtureBuilder('${root.path}/kelivo.sqlite');
    fixture.create();
    fixture.seedStandardRows();
    fixture.seedImagePrefs(enabled: true, quality: 72);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'reader payload round-trips through restoreLegacyPayload into a live v4 database',
    () async {
      final data = CuplivoV3Reader.readDatabase('${root.path}/kelivo.sqlite');

      final database = AppDatabase.open(file: File('${root.path}/kelivo.db'));
      final chatRepository = ChatDatabaseRepository(
        database,
        databaseFile: File('${root.path}/kelivo.db'),
      );
      await chatRepository.ensureReady();
      final businessRepository = BusinessRepository(database);
      final chatService = ChatService(existingRepository: chatRepository);
      final dataSync = DataSync(
        chatService: chatService,
        businessRepository: businessRepository,
      );

      final phases = <String>[];
      await dataSync.restoreLegacyPayload(
        chats: data.chatsJson,
        settings: data.settings,
        onPhase: (phase) => phases.add(phase.name),
      );

      // Conversations survive with ordered message ids.
      final conversations = chatService.getAllCompleteConversations();
      expect(conversations, hasLength(2));
      final conv1 = conversations.firstWhere((c) => c.id == 'conv-1');
      expect(conv1.title, 'First chat');
      expect(conv1.isPinned, isTrue);
      expect(conv1.assistantId, 'asst-1');
      expect(conv1.mcpServerIds, ['mcp-a', 'mcp-b']);

      final conv2 = conversations.firstWhere((c) => c.id == 'conv-2');
      expect(conv2.title, 'Group room');

      // Messages: content, reasoning metadata and tool-event parts.
      final conv1Messages = await chatService.loadMessages('conv-1');
      expect(conv1Messages, hasLength(2));
      final u1 = conv1Messages.firstWhere((m) => m.id == 'msg-u1');
      expect(u1.content, contains('Hello there'));
      // Reply citations survive the legacy importer now that ChatMessage
      // consumes quoteJson: the raw JSON string persists on the row, and the
      // tolerant `quote` getter treats a non-MessageQuote shape as absent.
      final a1Quote = conv1Messages.firstWhere((m) => m.id == 'msg-a1');
      expect(
        a1Quote.quoteJson,
        '{"messageId":"msg-u1","text":"Hello there"}',
      );
      expect(a1Quote.quote, isNull);
      final a1 = conv1Messages.firstWhere((m) => m.id == 'msg-a1');
      final toolParts = a1.parts.whereType<ToolCallPart>().toList();
      expect(
        toolParts.map((part) => part.payloadJson).join('\n'),
        contains('web_search'),
        reason: 'tool events from the fork DB must land as message parts',
      );

      // Business preferences round-trip.
      final snapshot = await businessRepository.readSnapshot();
      expect(snapshot.preferences['thinking_budget_v1'], 1024);
      expect(snapshot.preferences['app_locale_v1'], 'zh_CN');
      // The fork's one_click_compress_* prefs translate into known keys.
      expect(snapshot.preferences['image_upload_quality_v1'], 'custom');
      expect(snapshot.preferences['image_compress_custom_quality_v1'], 72);

      // Assistants route into entity rows with the fork payload intact.
      expect(
        snapshot.entityCount(BusinessEntityKind.assistant),
        1,
        reason: 'assistants_v1 must be restored from the fork DB',
      );
      final assistant = snapshot.entities[BusinessEntityKind.assistant]!.single;
      expect(assistant.id, 'asst-1');
      final assistantPayload =
          jsonDecode(assistant.payload) as Map<String, dynamic>;
      expect(assistantPayload['id'], 'asst-1');
      expect(assistantPayload['ocrMode'], 'always');

      expect(phases, containsAll(<String>['extracting', 'committing']));

      await chatRepository.close();
    },
  );

  test('restore is re-runnable after a simulated partial failure', () async {
    final data = CuplivoV3Reader.readDatabase('${root.path}/kelivo.sqlite');
    final database = AppDatabase.open(file: File('${root.path}/kelivo.db'));
    final chatRepository = ChatDatabaseRepository(
      database,
      databaseFile: File('${root.path}/kelivo.db'),
    );
    await chatRepository.ensureReady();
    final businessRepository = BusinessRepository(database);
    final chatService = ChatService(existingRepository: chatRepository);
    final dataSync = DataSync(
      chatService: chatService,
      businessRepository: businessRepository,
    );

    // First pass with a poisoned settings map throws before any domain
    // mutation (business payload is validated up front).
    final poisoned = <String, Object?>{
      ...data.settings,
      'assistants_v1': 'not-json',
    };
    await expectLater(
      dataSync.restoreLegacyPayload(chats: data.chatsJson, settings: poisoned),
      throwsA(isA<FormatException>()),
    );
    expect(chatService.getAllCompleteConversations(), isEmpty);

    // Second pass with the real payload completes and lands everything once.
    await dataSync.restoreLegacyPayload(
      chats: data.chatsJson,
      settings: data.settings,
    );
    expect(chatService.getAllCompleteConversations(), hasLength(2));

    // A third full overwrite re-run stays consistent (retry semantics).
    await dataSync.restoreLegacyPayload(
      chats: data.chatsJson,
      settings: data.settings,
    );
    expect(chatService.getAllCompleteConversations(), hasLength(2));
    final snapshot = await businessRepository.readSnapshot();
    expect(snapshot.entityCount(BusinessEntityKind.assistant), 1);

    await chatRepository.close();
  });
}
