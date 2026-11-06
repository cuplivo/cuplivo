import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/business_repository.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/chat/widgets/chat_gradient_background.dart';
import 'package:Cuplivo/features/chat/widgets/frosted/chat_frosted_backdrop.dart';
import 'package:Cuplivo/features/home/widgets/message_list_view.dart';
import 'package:Cuplivo/main.dart' as app;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';

/// Issue #1065, on a device.
///
/// Entering a group topic must not keep the selected assistant's flowing
/// gradient, and choosing an assistant from inside a group topic must open that
/// assistant's 1:1 instead of another topic of the group. Both are asserted on
/// what the screen shows — the gradient widget and the frosted backdrop's own
/// `backgroundActive` — because the backdrop spec can only be resolved from
/// inside a build.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'a group topic drops the gradient and a chosen assistant leaves it',
    (tester) async {
      final root = await _prepareEmptyInstallation();
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      await app.main();

      final list = find.byType(MessageListView);
      await _pumpUntil(
        tester,
        () => list.evaluate().isNotEmpty,
        what: 'the chat list',
      );

      final context = tester.element(list);
      final chat = context.read<ChatService>();
      final assistants = context.read<AssistantProvider>();
      final groups = context.read<GroupChatProvider>();

      // The list is mounted before `initChat` has restored the last
      // conversation and awaited the assistant provider, so wait for startup
      // rather than for the first frame.
      await _pumpUntil(
        tester,
        () => chat.currentConversationId != null,
        what: 'startup to open a conversation',
      );
      await _pumpUntil(
        tester,
        () => assistants.currentAssistantId != null,
        what: 'startup to restore the assistant',
      );
      await groups.loaded;

      // Set the scene the way a user would: an assistant with the flowing
      // gradient on, a second assistant with no history at all, and a group
      // holding both.
      final first = assistants.currentAssistant!;
      await assistants.updateAssistant(
        first.copyWith(useGradientBackground: true),
      );
      final secondId = await assistants.addAssistant(name: 'Assistant B');
      await assistants.updateAssistant(
        assistants.getById(secondId)!.copyWith(useGradientBackground: true),
      );
      final group = await groups.create(
        name: 'Reading',
        memberIds: [first.id, secondId],
      );

      // Enter the group from the drawer, so the topic is opened by the same
      // path a user takes (`_openGroup`) rather than by seeding a row.
      await _openDrawer(tester);
      await tester.tap(find.text(first.name).first);
      await _pumpFrames(tester, 8);
      await tester.tap(find.text('Reading').first);
      await _pumpUntil(
        tester,
        () =>
            chat
                .getConversation(chat.currentConversationId ?? '')
                ?.groupChatId ==
            group.id,
        what: 'the group topic to open',
      );
      expect(assistants.currentAssistantId, first.id);

      await _pumpFrames(tester, 10);
      expect(tester.takeException(), isNull);

      // Half one: a group topic has no owning assistant, so the selected
      // assistant's gradient must not be painted over it.
      expect(
        find.byType(ChatGradientBackground),
        findsNothing,
        reason: 'a group topic kept the selected assistant gradient (#1065)',
      );
      expect(_backdropActive(tester), isFalse);

      // Half two: choose the other assistant — which has no conversation — and
      // the chat that opens has to belong to it, not to the group.
      await _openDrawer(tester);
      await tester.tap(find.text(first.name).first);
      await _pumpFrames(tester, 8);
      await tester.tap(find.text('Assistant B').last);
      await _pumpUntil(tester, () {
        final id = chat.currentConversationId;
        if (id == null) return false;
        final convo = chat.getConversation(id);
        return convo != null && convo.groupChatId == null;
      }, what: 'the assistant switch to open a 1:1 chat');

      final opened = chat.getConversation(chat.currentConversationId!)!;
      expect(
        opened.groupChatId,
        isNull,
        reason: 'the switch opened another topic of the group (#1065)',
      );
      expect(opened.assistantId, secondId);
      expect(assistants.currentAssistantId, secondId);

      // The gradient comes back for a real 1:1, so the assertion above is not
      // "the gradient is off everywhere".
      await _pumpFrames(tester, 10);
      expect(tester.takeException(), isNull);
      expect(find.byType(ChatGradientBackground), findsWidgets);
      expect(_backdropActive(tester), isTrue);
    },
  );
}

/// A disposable installation: the app writes into a temp directory, and the
/// migration receipt is there so the startup gate does not treat it as a
/// pre-business database.
Future<Directory> _prepareEmptyInstallation() async {
  final root = await Directory.systemTemp.createTemp('group_switch_');
  final original = PathProviderPlatform.instance;
  PathProviderPlatform.instance = _Paths(root.path);
  addTearDown(() => PathProviderPlatform.instance = original);

  final database = AppDatabase.open(
    file: File('${root.path}/${AppDatabase.databaseFileName}'),
  );
  final repository = ChatDatabaseRepository(database);
  await repository.ensureReady();
  final business = BusinessRepository(database);
  await business.writeMigrationReceipt();
  await business.setPreference('display_new_chat_on_launch_v1', false);
  await repository.close();
  return root;
}

Future<void> _openDrawer(WidgetTester tester) async {
  await tester.tap(_drawerMenuButton());
  await _pumpFrames(tester, 10);
}

/// The drawer's leading menu button, found by the icon asset it draws.
Finder _drawerMenuButton() {
  return find.byWidgetPredicate(
    (widget) =>
        widget is SvgPicture &&
        widget.bytesLoader is SvgAssetLoader &&
        (widget.bytesLoader as SvgAssetLoader).assetName.contains('list.svg'),
  );
}

bool _backdropActive(WidgetTester tester) {
  return tester
      .widget<ChatFrostedBackdropScope>(
        find.byType(ChatFrostedBackdropScope).first,
      )
      .backgroundActive;
}

/// The gradient animates forever, so `pumpAndSettle` never settles: pump a
/// fixed number of real frames instead.
Future<void> _pumpFrames(WidgetTester tester, int frames) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  String? what,
  int steps = 200,
}) async {
  for (var i = 0; i < steps; i++) {
    if (done()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail('timed out waiting for ${what ?? 'the condition'}');
}

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
