import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/group_chat_member.dart';
import '../../../core/models/group_chat_message.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/group_chat_service.dart';
import '../../../core/services/group_chat/group_chat_orchestrator.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../home/widgets/assistant_avatar.dart';
import '../../home/widgets/assistant_entry_actions.dart';
import '../../home/widgets/chat_input_bar.dart';
import '../group_chat_navigation.dart';
import '../widgets/group_avatar.dart';

/// Map orchestrator error codes to localized user-facing text.
///
/// Used both as a full SnackBar message (pre-flight throws) and as the
/// `{reason}` for [AppLocalizations.groupChatReplyFailed] after the user
/// message has already been persisted.
String localizeGroupChatError(
  AppLocalizations l10n, {
  String? code,
  String? detail,
}) {
  final d = (detail ?? '').trim();
  switch (code) {
    case GroupChatErrorCode.noDirectorModel:
      return l10n.groupChatErrorNoDirectorModel;
    case GroupChatErrorCode.directorModelNoTools:
      return l10n.groupChatErrorDirectorModelNoTools;
    case GroupChatErrorCode.directorNoDecision:
      return l10n.groupChatErrorDirectorNoDecision;
    case GroupChatErrorCode.directorFailed:
      return l10n.groupChatErrorDirectorFailed(
        d.isEmpty ? l10n.groupChatSendFailed : d,
      );
    case GroupChatErrorCode.memberNoModel:
      return l10n.groupChatErrorMemberNoModel;
    case GroupChatErrorCode.memberFailed:
      return l10n.groupChatErrorMemberFailed(
        d.isEmpty ? l10n.groupChatSendFailed : d,
      );
    case GroupChatErrorCode.memberNotFound:
      return l10n.groupChatErrorMemberNotFound;
    case GroupChatErrorCode.notEnoughMembers:
      return l10n.groupChatErrorNotEnoughMembers;
    case GroupChatErrorCode.groupNotFound:
      return l10n.groupChatErrorGroupNotFound;
    case GroupChatErrorCode.alreadyRunning:
      return l10n.groupChatErrorAlreadyRunning;
    case GroupChatErrorCode.emptyContent:
      return l10n.groupChatSendFailed;
    case GroupChatErrorCode.cancelled:
      return l10n.groupChatSendFailed;
    default:
      if (d.isNotEmpty) return d;
      return l10n.groupChatSendFailed;
  }
}

/// Group chat conversation page (one continuous timeline per group).
class GroupChatPage extends StatefulWidget {
  const GroupChatPage({super.key, required this.groupId});

  final String groupId;

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends State<GroupChatPage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _inputFocus = FocusNode();
  bool _loading = true;
  bool _sending = false;
  List<GroupChatMessage> _messages = const [];
  List<GroupChatMember> _members = const [];
  GroupChatService? _svc;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _svc?.removeListener(_onServiceChanged);
    _inputController.dispose();
    _scrollController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final svc = context.read<GroupChatService>();
    _svc = svc;
    svc.addListener(_onServiceChanged);
    await svc.ensureLoaded();
    svc.setCurrentGroup(widget.groupId);
    final messages = await svc.getMessages(widget.groupId);
    final members = await svc.getMembers(widget.groupId);
    if (!mounted) return;
    setState(() {
      _messages = messages;
      _members = members;
      _loading = false;
    });
    _scrollToBottom(animate: false);
  }

  void _onServiceChanged() {
    if (!mounted || _loading) return;
    unawaited(_softRefresh());
  }

  Future<void> _softRefresh() async {
    final svc = _svc ?? context.read<GroupChatService>();
    final messages = await svc.getMessages(widget.groupId);
    final members = await svc.getMembers(widget.groupId);
    if (!mounted) return;
    final atBottom = !_scrollController.hasClients
        ? true
        : (_scrollController.position.maxScrollExtent -
                  _scrollController.position.pixels) <
              80;
    setState(() {
      _messages = messages;
      _members = members;
      if (svc.isGroupGenerating(widget.groupId)) {
        _sending = true;
      }
    });
    if (atBottom) _scrollToBottom();
  }

  Future<void> _reloadMessages() async {
    final svc = context.read<GroupChatService>();
    final messages = await svc.reloadMessages(widget.groupId);
    final members = await svc.getMembers(widget.groupId);
    if (!mounted) return;
    setState(() {
      _messages = messages;
      _members = members;
    });
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
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

  Future<ChatInputSubmissionResult> _onSend(ChatInputData data) async {
    final l10n = AppLocalizations.of(context)!;
    final text = data.text.trim();
    if (text.isEmpty || _sending) {
      return ChatInputSubmissionResult.rejected;
    }
    final svc = context.read<GroupChatService>();
    final hasOrchestrator = svc.orchestrator != null;
    setState(() => _sending = true);
    try {
      if (hasOrchestrator) {
        // Director loop is silent in UI; member replies stream via service notify.
        unawaited(
          svc
              .sendUserMessage(groupId: widget.groupId, content: text)
              .then((result) async {
                if (!mounted) return;
                await _reloadMessages();
                if (!mounted) return;
                _scrollToBottom();
                if (!result.isSuccess &&
                    result.errorCode != null &&
                    result.errorCode != GroupChatErrorCode.cancelled) {
                  final reason = localizeGroupChatError(
                    l10n,
                    code: result.errorCode,
                    detail: result.errorMessage,
                  );
                  // User message already landed — phrase as reply failure.
                  showAppSnackBar(
                    context,
                    message: l10n.groupChatReplyFailed(reason),
                    type: NotificationType.error,
                  );
                }
              })
              .catchError((Object e) {
                if (!mounted) return;
                final code = e is GroupChatOrchestratorException
                    ? e.code
                    : null;
                final detail = e is GroupChatOrchestratorException
                    ? e.message
                    : e.toString();
                final reason = localizeGroupChatError(
                  l10n,
                  code: code,
                  detail: detail,
                );
                // Pre-flight failures (no user msg) still get a concrete reason.
                showAppSnackBar(
                  context,
                  message: reason,
                  type: NotificationType.error,
                );
              })
              .whenComplete(() {
                if (mounted) setState(() => _sending = false);
              }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 60));
        if (!mounted) return ChatInputSubmissionResult.sent;
        await _reloadMessages();
        _scrollToBottom();
        return ChatInputSubmissionResult.sent;
      }

      await svc.addMessage(
        GroupChatMessage(groupId: widget.groupId, role: 'user', content: text),
      );
      if (!mounted) return ChatInputSubmissionResult.sent;
      await _reloadMessages();
      _scrollToBottom();
      return ChatInputSubmissionResult.sent;
    } catch (e) {
      if (mounted) {
        final code = e is GroupChatOrchestratorException ? e.code : null;
        final detail = e is GroupChatOrchestratorException
            ? e.message
            : e.toString();
        showAppSnackBar(
          context,
          message: localizeGroupChatError(l10n, code: code, detail: detail),
          type: NotificationType.error,
        );
      }
      return ChatInputSubmissionResult.rejected;
    } finally {
      if (mounted && !hasOrchestrator) {
        setState(() => _sending = false);
      }
    }
  }

  int get _memberCount {
    if (_members.isNotEmpty) return _members.length;
    final g = context.read<GroupChatService>().getGroup(widget.groupId);
    return g?.memberIds.length ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final svc = context.watch<GroupChatService>();
    final group = svc.getGroup(widget.groupId);
    final title = group?.title ?? l10n.groupChatDefaultTitle;
    final ap = context.watch<AssistantProvider>();
    final up = context.watch<UserProvider>();

    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.groupChatBackTooltip,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            size: 22,
            minSize: 44,
            onTap: () => Navigator.of(context).maybePop(),
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.6),
                      fontWeight: AppFontWeights.medium,
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
                if (mounted) await _reloadMessages();
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
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _messages.isEmpty
                ? Center(
                    child: Text(
                      l10n.groupChatMessageEmpty,
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final m = _messages[index];
                      return _GroupMessageBubble(
                        message: m,
                        assistant: m.speakerAssistantId == null
                            ? null
                            : ap.getById(m.speakerAssistantId!),
                        userName: up.name,
                        userAvatarType: up.avatarType,
                        userAvatarValue: up.avatarValue,
                        meLabel: l10n.groupChatSettingsUserLabel,
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: ChatInputBar(
                controller: _inputController,
                focusNode: _inputFocus,
                loading: _sending,
                hideChatCapabilityButtons: true,
                showMoreButton: false,
                showMiniMapButton: false,
                showQuickPhraseButton: false,
                showDocumentProcessingButton: false,
                supportsReasoning: false,
                showMcpButton: false,
                onSend: _onSend,
                onStop: _sending
                    ? () {
                        unawaited(
                          context.read<GroupChatService>().cancelGeneration(
                            widget.groupId,
                          ),
                        );
                      }
                    : null,
                sendButtonTooltip: l10n.groupChatInputPlaceholder,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupMessageBubble extends StatelessWidget {
  const _GroupMessageBubble({
    required this.message,
    required this.assistant,
    required this.userName,
    required this.userAvatarType,
    required this.userAvatarValue,
    required this.meLabel,
  });

  final GroupChatMessage message;
  final Assistant? assistant;
  final String userName;
  final String? userAvatarType;
  final String? userAvatarValue;
  final String meLabel;

  bool get _isUser => message.role == 'user';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final name = _isUser
        ? (userName.trim().isEmpty ? meLabel : userName)
        : (assistant?.name ?? '?');

    final bubbleColor = _isUser
        ? cs.primary.withValues(alpha: isDark ? 0.28 : 0.14)
        : (isDark ? Colors.white10 : Colors.white.withValues(alpha: 0.96));

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isUser)
            _UserMiniAvatar(
              name: name,
              avatarType: userAvatarType,
              avatarValue: userAvatarValue,
              size: 34,
            )
          else
            GestureDetector(
              onTap: assistant == null
                  ? null
                  : () => AssistantEntryActions.openAssistantSettings(
                      context,
                      assistant!.id,
                    ),
              child: AssistantAvatar(assistant: assistant, size: 34),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: AppFontWeights.medium,
                    color: cs.onSurface.withValues(alpha: 0.65),
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: cs.outlineVariant.withValues(
                        alpha: isDark ? 0.12 : 0.08,
                      ),
                      width: 0.6,
                    ),
                  ),
                  child: SelectableText(
                    message.content,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.35,
                      color: cs.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UserMiniAvatar extends StatelessWidget {
  const _UserMiniAvatar({
    required this.name,
    required this.avatarType,
    required this.avatarValue,
    this.size = 34,
  });

  final String name;
  final String? avatarType;
  final String? avatarValue;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final type = avatarType;
    final value = (avatarValue ?? '').trim();

    if (type == 'emoji' && value.isNotEmpty) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Text(
          value.characters.take(1).toString(),
          style: TextStyle(fontSize: size * 0.48),
        ),
      );
    }
    // Fallback initial; url/file handled lightly via GroupAvatar-like path would bloat — MVP letter.
    final letter = name.trim().isNotEmpty ? name.characters.first : '?';
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      child: Text(
        letter,
        style: TextStyle(
          color: cs.primary,
          fontWeight: AppFontWeights.emphasis,
          fontSize: size * 0.42,
        ),
      ),
    );
  }
}
