import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/group_chat_message.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/mcp_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/user_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/chat/group_chat_service.dart';
import 'package:Cuplivo/core/services/mcp/mcp_tool_service.dart';
import 'package:Cuplivo/features/group_chat/services/group_member_generation_service.dart';
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    'prepares a first DeepSeek member turn above the Localizations tree',
    (tester) async {
      late BuildContext context;
      final settings = SettingsProvider();
      await settings.setAppLocale(const Locale('zh', 'CN'));
      final chatService = ChatService();
      final groupChatService = GroupChatService(chatService: chatService);
      final userProvider = UserProvider();
      final assistantProvider = AssistantProvider(chatService: chatService);
      final mcpProvider = McpProvider(chatService: chatService);
      final mcpToolService = McpToolService();
      final toolApprovalService = ToolApprovalService();
      final askUserService = AskUserInteractionService();

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: settings),
              ChangeNotifierProvider.value(value: userProvider),
              ChangeNotifierProvider.value(value: assistantProvider),
              ChangeNotifierProvider.value(value: mcpProvider),
              ChangeNotifierProvider.value(value: mcpToolService),
              ChangeNotifierProvider.value(value: toolApprovalService),
              ChangeNotifierProvider.value(value: askUserService),
            ],
            child: Builder(
              builder: (buildContext) {
                context = buildContext;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      final service = GroupMemberGenerationService(
        context: context,
        chatService: chatService,
        groupChatService: groupChatService,
      );
      final assistant = Assistant(
        id: 'a1',
        name: 'Alice',
        systemPrompt: 'locale={locale}; assistant={assistant_name}',
        chatModelProvider: 'DeepSeek',
        chatModelId: 'deepseek-chat',
      );

      final prepared = await service.prepare(
        groupId: 'group-1',
        timeline: [
          GroupChatMessage(
            id: 'user-1',
            groupId: 'group-1',
            role: 'user',
            content: '你们好',
          ),
        ],
        assistant: assistant,
        assistantNames: const <String, String>{'a1': 'Alice'},
        providerKey: 'DeepSeek',
        modelId: 'deepseek-chat',
        settings: settings,
      );

      final systemMessage = prepared.apiMessages.firstWhere(
        (message) => message['role'] == 'system',
      );
      expect(systemMessage['content'], contains('locale=zh-CN'));
      expect(systemMessage['content'], contains('assistant=Alice'));
      expect(prepared.apiMessages.last['role'], 'user');
      expect(prepared.apiMessages.last['content'], contains('你们好'));

      groupChatService.dispose();
      chatService.dispose();
      settings.dispose();
      userProvider.dispose();
      assistantProvider.dispose();
      mcpProvider.dispose();
      mcpToolService.dispose();
      toolApprovalService.dispose();
      askUserService.dispose();
    },
  );
}
