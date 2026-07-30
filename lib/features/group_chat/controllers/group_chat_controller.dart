import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/models/group_chat_member.dart';
import '../../../core/models/group_chat_message.dart';
import '../../../core/services/chat/group_chat_service.dart';
import '../../../core/services/group_chat/group_chat_orchestrator.dart';

typedef GroupMessageUiRestorer = void Function(List<GroupChatMessage> messages);

/// Page-scoped coordinator for one group chat.
///
/// Persistence stays in [GroupChatService], turn scheduling stays in
/// [GroupChatOrchestrator], and this controller owns only the page-facing
/// loading/sending state plus the current group snapshot.
class GroupChatController extends ChangeNotifier {
  GroupChatController({
    required this.groupId,
    required this.groupChatService,
    required this.orchestrator,
    required this.restoreMessageUiState,
  });

  final String groupId;
  final GroupChatService groupChatService;
  final GroupChatOrchestrator orchestrator;
  final GroupMessageUiRestorer restoreMessageUiState;

  List<GroupChatMessage> _messages = const <GroupChatMessage>[];
  List<GroupChatMember> _members = const <GroupChatMember>[];
  bool _isLoading = true;
  bool _isSending = false;
  bool _isDisposed = false;
  bool _isListening = false;
  bool _reloadRequested = false;
  Future<void>? _initializeTask;
  Future<void>? _reloadTask;

  List<GroupChatMessage> get messages => List.unmodifiable(_messages);
  List<GroupChatMember> get members => List.unmodifiable(_members);
  bool get isLoading => _isLoading;
  bool get isSending => _isSending;

  Future<void> initialize() => _initializeTask ??= _initialize();

  Future<void> _initialize() async {
    try {
      await groupChatService.ensureLoaded();
      if (_isDisposed) return;
      groupChatService.setCurrentGroup(groupId);
      groupChatService.addListener(_handleDependencyChanged);
      orchestrator.addListener(_handleDependencyChanged);
      _isListening = true;
      await reload();
    } finally {
      if (!_isDisposed) {
        _isLoading = false;
        _syncSendingState();
        notifyListeners();
      }
    }
  }

  Future<void> reload() {
    if (_isDisposed) return Future<void>.value();
    _reloadRequested = true;
    return _reloadTask ??= _drainReloadRequests();
  }

  Future<void> _drainReloadRequests() async {
    try {
      while (_reloadRequested && !_isDisposed) {
        _reloadRequested = false;
        final messages = await groupChatService.getMessages(groupId);
        final members = await groupChatService.getMembers(groupId);
        if (_isDisposed) return;
        _messages = List<GroupChatMessage>.of(messages);
        _members = List<GroupChatMember>.of(members);
        restoreMessageUiState(_messages);
        _syncSendingState();
        notifyListeners();
      }
    } finally {
      _reloadTask = null;
    }
  }

  Future<GroupChatTurnResult> send(String content) async {
    final text = content.trim();
    if (text.isEmpty || _isSending) {
      throw StateError('Group chat cannot send the current input');
    }
    _isSending = true;
    notifyListeners();
    try {
      final result = await orchestrator.sendUserMessage(
        groupId: groupId,
        content: text,
      );
      await reload();
      return result;
    } finally {
      if (!_isDisposed) {
        _syncSendingState();
        notifyListeners();
      }
    }
  }

  Future<void> cancel() => orchestrator.cancel(groupId);

  void _handleDependencyChanged() {
    if (_isDisposed) return;
    _syncSendingState();
    notifyListeners();
    unawaited(reload());
  }

  void _syncSendingState() {
    _isSending = orchestrator.isRunning(groupId);
  }

  @override
  void dispose() {
    _isDisposed = true;
    if (_isListening) {
      groupChatService.removeListener(_handleDependencyChanged);
      orchestrator.removeListener(_handleDependencyChanged);
    }
    super.dispose();
  }
}
