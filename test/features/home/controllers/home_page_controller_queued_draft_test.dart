import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/features/home/controllers/home_page_controller.dart';
import 'package:Cuplivo/features/home/controllers/scroll_controller.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_bar.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';

/// Records the persisted-draft drops the view model asks for.
class _Media extends ChatInputBarController {
  int clearedPersistedDrafts = 0;

  @override
  void clearPersistedDraft() => clearedPersistedDrafts++;
}

class _EmptyChatService extends ChatService {
  @override
  bool isConversationFullyCached(String conversationId) => true;

  @override
  List<Conversation> getAllConversations() => const <Conversation>[];
}

Widget _app(_EmptyChatService service, GlobalKey<_HarnessState> key) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(createBusinessTestPreferences()),
        ),
        ChangeNotifierProvider<ChatService>.value(value: service),
        ChangeNotifierProvider(
          create: (_) =>
              AssistantProvider(preferences: createBusinessTestPreferences()),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: _Harness(key: key),
      ),
    );

class _Harness extends StatefulWidget {
  const _Harness({super.key});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> with TickerProviderStateMixin {
  final text = TextEditingController();
  final media = _Media();
  final focus = FocusNode();
  final scroll = ChatAutoFollowScrollController();
  final scaffoldKey = GlobalKey<ScaffoldState>();
  late final HomePageController controller;

  @override
  void initState() {
    super.initState();
    controller = HomePageController(
      context: context,
      vsync: this,
      scaffoldKey: scaffoldKey,
      inputBarKey: GlobalKey(),
      inputFocus: focus,
      inputController: text,
      mediaController: media,
      scrollController: scroll,
    );
  }

  @override
  void dispose() {
    controller.dispose();
    text.dispose();
    focus.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    key: scaffoldKey,
    body: TextField(controller: text, focusNode: focus),
  );
}

void main() {
  testWidgets('队列真正发送后由控制器清掉草稿安全副本', (tester) async {
    final service = _EmptyChatService();
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_app(service, key));
    final state = key.currentState!;

    // The view model fires this only from the success branch of
    // `_drainQueuedInputIfReady`; a failed drain re-queues and keeps the draft,
    // so the composer must not clear it on its own.
    final callback = state.controller.debugViewModel.onQueuedInputDrained;
    expect(callback, isNotNull, reason: '队列排空回调必须接上');
    callback!.call();
    expect(state.media.clearedPersistedDrafts, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });
}
