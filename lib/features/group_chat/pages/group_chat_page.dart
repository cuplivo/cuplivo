import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:scrollview_observer/scrollview_observer.dart';

import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/group_chat_member.dart';
import '../../../core/models/group_chat_message.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/services/chat/group_chat_service.dart';
import '../../../core/services/group_chat/group_chat_context_projector.dart';
import '../../../core/services/group_chat/group_chat_orchestrator.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../chat/widgets/message_more_sheet.dart';
import '../../home/widgets/chat_input_bar.dart';
import '../../home/widgets/message_list_view.dart';
import '../controllers/group_chat_controller.dart';
import '../group_chat_navigation.dart';
import '../services/group_member_stream_service.dart';
import '../widgets/group_avatar.dart';

String localizeGroupChatError(
  AppLocalizations l10n, {
  String? code,
  String? detail,
}) {
  final normalizedDetail = (detail ?? '').trim();
  switch (code) {
    case GroupChatErrorCode.noDirectorModel:
      return l10n.groupChatErrorNoDirectorModel;
    case GroupChatErrorCode.directorModelNoTools:
      return l10n.groupChatErrorDirectorModelNoTools;
    case GroupChatErrorCode.directorNoDecision:
      return l10n.groupChatErrorDirectorNoDecision;
    case GroupChatErrorCode.directorFailed:
      return l10n.groupChatErrorDirectorFailed(
        normalizedDetail.isEmpty ? l10n.groupChatSendFailed : normalizedDetail,
      );
    case GroupChatErrorCode.memberNoModel:
      return l10n.groupChatErrorMemberNoModel;
    case GroupChatErrorCode.memberFailed:
      return l10n.groupChatErrorMemberFailed(
        normalizedDetail.isEmpty ? l10n.groupChatSendFailed : normalizedDetail,
      );
    case GroupChatErrorCode.memberNotFound:
      return l10n.groupChatErrorMemberNotFound;
    case GroupChatErrorCode.notEnoughMembers:
      return l10n.groupChatErrorNotEnoughMembers;
    case GroupChatErrorCode.groupNotFound:
      return l10n.groupChatErrorGroupNotFound;
    case GroupChatErrorCode.alreadyRunning:
      return l10n.groupChatErrorAlreadyRunning;
    default:
      return normalizedDetail.isEmpty
          ? l10n.groupChatSendFailed
          : normalizedDetail;
  }
}

class GroupChatPage extends StatefulWidget {
  const GroupChatPage({super.key, required this.groupId});

  final String groupId;

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends State<GroupChatPage> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocus = FocusNode();
  final ValueNotifier<bool> _isProcessingFiles = ValueNotifier<bool>(false);
  late final ListObserverController _observerController =
      ListObserverController(controller: _scrollController);

  GroupChatController? _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _controller?.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    _inputFocus.dispose();
    _isProcessingFiles.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final controller = GroupChatController(
      groupId: widget.groupId,
      groupChatService: context.read<GroupChatService>(),
      orchestrator: context.read<GroupChatOrchestrator>(),
      restoreMessageUiState: context
          .read<GroupMemberStreamService>()
          .restoreMessages,
    );
    _controller = controller..addListener(_onStateChanged);
    await controller.initialize();
    if (!mounted) return;
    _scrollToBottom(animate: false);
  }

  void _onStateChanged() {
    if (!mounted) return;
    final wasNearBottom = !_scrollController.hasClients
        ? true
        : _scrollController.position.maxScrollExtent -
                  _scrollController.position.pixels <
              80;
    setState(() {});
    if (wasNearBottom) _scrollToBottom();
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (animate) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  Future<ChatInputSubmissionResult> _onSend(ChatInputData input) async {
    final text = input.text.trim();
    final controller = _controller;
    if (text.isEmpty || controller == null || controller.isSending) {
      return ChatInputSubmissionResult.rejected;
    }
    final l10n = AppLocalizations.of(context)!;
    unawaited(
      controller
          .send(text)
          .then((result) {
            if (!mounted ||
                result.isSuccess ||
                result.errorCode == GroupChatErrorCode.cancelled) {
              return;
            }
            final reason = localizeGroupChatError(
              l10n,
              code: result.errorCode,
              detail: result.errorMessage,
            );
            showAppSnackBar(
              context,
              message: l10n.groupChatReplyFailed(reason),
              type: NotificationType.error,
            );
          })
          .catchError((Object error) {
            if (!mounted) return;
            showAppSnackBar(
              context,
              message: localizeGroupChatError(
                l10n,
                code: error is GroupChatOrchestratorException
                    ? error.code
                    : null,
                detail: error is GroupChatOrchestratorException
                    ? error.message
                    : error.toString(),
              ),
              type: NotificationType.error,
            );
          }),
    );
    return ChatInputSubmissionResult.sent;
  }

  void _toggleReasoning(String messageId) {
    final data = context
        .read<GroupMemberStreamService>()
        .streamController
        .reasoning[messageId];
    if (data == null) return;
    setState(() => data.expanded = !data.expanded);
  }

  void _toggleReasoningSegment(String messageId, int index) {
    final segments = context
        .read<GroupMemberStreamService>()
        .streamController
        .reasoningSegments[messageId];
    if (segments == null || index < 0 || index >= segments.length) return;
    setState(() => segments[index].expanded = !segments[index].expanded);
  }

  int get _memberCount {
    final members = _controller?.members ?? const <GroupChatMember>[];
    if (members.isNotEmpty) return members.length;
    return context
            .read<GroupChatService>()
            .getGroup(widget.groupId)
            ?.memberIds
            .length ??
        0;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final service = context.read<GroupChatService>();
    final assistants = context.watch<AssistantProvider>();
    final streamService = context.watch<GroupMemberStreamService>();
    final controller = _controller;
    final messages = controller?.messages ?? const <GroupChatMessage>[];
    final loading = controller?.isLoading ?? true;
    final sending = controller?.isSending ?? false;
    final group = service.getGroup(widget.groupId);
    final title = group?.title ?? l10n.groupChatDefaultTitle;
    final chatMessages = messages
        .map(GroupChatContextProjector.toChatMessage)
        .toList(growable: false);
    final messagesById = <String, GroupChatMessage>{
      for (final message in messages) message.id: message,
    };
    final byGroup = <String, List<ChatMessage>>{
      for (final message in chatMessages) message.id: <ChatMessage>[message],
    };
    final stream = streamService.streamController;

    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.groupChatBackTooltip,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            size: 22,
            minSize: 44,
            onTap: () => closeGroupPage(context),
            semanticLabel: l10n.groupChatBackTooltip,
          ),
        ),
        title: Row(
          children: [
            GroupAvatar(title: title, avatar: group?.avatar, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: AppFontWeights.emphasis,
                    ),
                  ),
                  Text(
                    l10n.groupChatMembersCount(_memberCount),
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Tooltip(
            message: l10n.groupChatOpenSettingsTooltip,
            child: IosIconButton(
              icon: Lucide.Menu,
              size: 22,
              minSize: 44,
              onTap: () async {
                await openGroupSettings(context, widget.groupId);
                if (mounted) await controller?.reload();
              },
              semanticLabel: l10n.groupChatOpenSettingsTooltip,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : chatMessages.isEmpty
                ? Center(
                    child: Text(
                      l10n.groupChatMessageEmpty,
                      style: TextStyle(
                        color: colorScheme.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  )
                : MessageListView(
                    scrollController: _scrollController,
                    observerController: _observerController,
                    messages: chatMessages,
                    byGroup: byGroup,
                    versionSelections: const <String, int>{},
                    reasoning: stream.reasoning,
                    reasoningSegments: stream.reasoningSegments,
                    contentSplits: stream.contentSplits,
                    toolParts: stream.toolParts,
                    translations: const <String, TranslationUiState>{},
                    selecting: false,
                    selectedItems: const <String>{},
                    dividerPadding: EdgeInsets.zero,
                    isProcessingFiles: _isProcessingFiles,
                    streamingContentNotifier: stream.streamingContentNotifier,
                    assistantForMessage: (message) {
                      final groupMessage = messagesById[message.id];
                      final assistantId = groupMessage?.speakerAssistantId;
                      return assistantId == null
                          ? null
                          : assistants.getById(assistantId);
                    },
                    forceAssistantIdentity: true,
                    hideMoreActions: () => MessageMoreAction.values.toSet(),
                    onToggleReasoning: _toggleReasoning,
                    onToggleReasoningSegment: _toggleReasoningSegment,
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: ChatInputBar(
                controller: _inputController,
                focusNode: _inputFocus,
                loading: sending,
                capabilities: ChatInputCapabilities.textOnly,
                showMoreButton: false,
                showMiniMapButton: false,
                showQuickPhraseButton: false,
                showDocumentProcessingButton: false,
                supportsReasoning: false,
                showMcpButton: false,
                onSend: _onSend,
                onStop: sending ? () => unawaited(controller?.cancel()) : null,
                sendButtonTooltip: l10n.groupChatInputPlaceholder,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
