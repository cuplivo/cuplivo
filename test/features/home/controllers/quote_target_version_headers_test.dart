import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:Cuplivo/core/models/message_quote.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/home/controllers/chat_controller.dart';
import 'package:Cuplivo/utils/sandbox_path_resolver.dart';

/// The window a reply citation's chip resolves against once the quoted message's
/// group selects another revision (docs/adr/0012).
///
/// `MessageListView` resolves a citation by **message slot**, and it learns the
/// ids that slot has held from `ChatController.groupedMessages`, which carries
/// the version headers. A version switch moves which revision the group shows,
/// so the cited row leaves `collapsedMessages` — the row the group shows now has
/// to answer for it instead. This pins that other half of the premise; the chip's
/// own rendering is covered by
/// `test/features/home/widgets/message_list_view_quote_target_test.dart`.
class _Paths extends PathProviderPlatform {
  _Paths(this.path);
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
  late Directory directory;
  late PathProviderPlatform paths;
  late ChatService service;
  late ChatController controller;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cuplivo_quote_headers_');
    paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    SandboxPathResolver.debugSetDirs(
      docsDir: directory.path,
      supportDir: directory.path,
    );
    service = ChatService();
    controller = ChatController(chatService: service);
    await service.init();
  });

  tearDown(() async {
    controller.dispose();
    await service.close();
    await Hive.close();
    PathProviderPlatform.instance = paths;
    SandboxPathResolver.debugSetDirs(docsDir: null, supportDir: null);
    await directory.delete(recursive: true);
  });

  test('a version switch keeps the cited revision id in its group', () async {
    final conversation = await service.createConversation(title: 'Reply');
    final target = await service.addMessage(
      conversationId: conversation.id,
      role: 'assistant',
      content: 'ORIGINAL ANSWER',
    );
    final reply = await service.addMessage(
      conversationId: conversation.id,
      role: 'user',
      content: 'about that?',
      quote: MessageQuote(id: target.id),
    );
    await service.appendMessageVersion(
      messageId: target.id,
      content: 'REGENERATED ANSWER',
    );
    await controller.setCurrentConversationAndLoad(
      service.getConversation(conversation.id),
    );
    final groupId = target.groupId ?? target.id;

    // The revision the reply was made against is the selected one: it is on
    // screen, so an exact id answers the citation.
    await controller.setSelectedVersion(groupId, 0);
    expect(controller.collapsedMessages.map((m) => m.id), contains(target.id));

    // An ordinary version switch — and equally a regeneration or an
    // edit-and-resend, which append through the same path.
    await controller.setSelectedVersion(groupId, 1);
    final switched = controller.collapsedMessages;

    // The citation is untouched, and the row it names is no longer on screen.
    expect(switched.firstWhere((m) => m.id == reply.id).quote?.id, target.id);
    expect(switched.map((m) => m.id), isNot(contains(target.id)));
    expect(switched.map((m) => m.content), contains('REGENERATED ANSWER'));

    // Its id survives in the group, which is what the chip's slot resolution
    // reads (`MessageListView._quoteTargets`). Without this the chip could only
    // ever show a stub for a message that is still there.
    expect(
      controller.groupedMessages[groupId]!.map((m) => m.id),
      contains(target.id),
    );

    // And the revision the slot shows now is the regenerated one — the row the
    // chip resolves the switched-away citation to.
    final shown = switched.firstWhere((m) => (m.groupId ?? m.id) == groupId);
    expect(shown.content, 'REGENERATED ANSWER');
    expect(
      controller.groupedMessages[groupId]!.map((m) => m.id),
      contains(shown.id),
    );
  });
}
