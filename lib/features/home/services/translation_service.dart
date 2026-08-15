import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/api/plain_text_collector.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../settings/widgets/language_select_sheet.dart';

/// 翻译结果类型
enum TranslationResultType {
  /// 翻译成功
  success,

  /// 用户选择清除翻译
  cleared,

  /// 用户取消选择语言
  cancelled,

  /// 未配置翻译模型
  noModelConfigured,

  /// 翻译出错
  error,
}

/// 翻译结果
class TranslationResult {
  TranslationResult({required this.type, this.errorMessage, this.translation});

  final TranslationResultType type;
  final String? errorMessage;
  final String? translation;

  bool get isSuccess => type == TranslationResultType.success;
  bool get isCleared => type == TranslationResultType.cleared;
  bool get isCancelled => type == TranslationResultType.cancelled;
}

/// 消息翻译服务
///
/// 功能：
/// - 显示语言选择器
/// - 调用翻译 API
/// - 流式更新翻译结果
/// - 保存翻译到数据库
class TranslationService {
  TranslationService({required this.chatService, required this._getContext});

  final ChatService chatService;
  final BuildContext Function() _getContext;
  final Map<String, _TranslationRequest> _activeRequests =
      <String, _TranslationRequest>{};
  final Map<String, _TranslationRequest> _pendingSelections =
      <String, _TranslationRequest>{};

  static const Duration liveUpdateInterval = Duration(milliseconds: 120);

  void cancelMessage(String messageId) {
    final request = _activeRequests.remove(messageId);
    if (request != null) {
      request.cancelled = true;
      ChatApiService.cancelRequest(request.requestId);
    }
    final selection = _pendingSelections.remove(messageId);
    selection?.cancelled = true;
  }

  void cancelAll() {
    final messageIds = <String>{
      ..._activeRequests.keys,
      ..._pendingSelections.keys,
    };
    for (final messageId in messageIds) {
      cancelMessage(messageId);
    }
  }

  _TranslationRequest _beginSelection(String messageId) {
    final previous = _pendingSelections.remove(messageId);
    previous?.cancelled = true;
    final request = _TranslationRequest(
      messageId: messageId,
      requestId:
          'translation_${messageId}_${DateTime.now().microsecondsSinceEpoch}',
    );
    _pendingSelections[messageId] = request;
    return request;
  }

  bool _isCurrentSelection(_TranslationRequest request) =>
      identical(_pendingSelections[request.messageId], request) &&
      !request.cancelled;

  void _finishSelection(_TranslationRequest request) {
    if (identical(_pendingSelections[request.messageId], request)) {
      _pendingSelections.remove(request.messageId);
    }
  }

  _TranslationRequest _beginRequest(String messageId) {
    final previous = _activeRequests.remove(messageId);
    if (previous != null) {
      previous.cancelled = true;
      ChatApiService.cancelRequest(previous.requestId);
    }
    final request = _TranslationRequest(
      messageId: messageId,
      requestId:
          'translation_${messageId}_${DateTime.now().microsecondsSinceEpoch}',
    );
    _activeRequests[messageId] = request;
    return request;
  }

  bool hasActiveRequest(String messageId) =>
      _activeRequests.containsKey(messageId);

  bool _isCurrent(_TranslationRequest request) =>
      identical(_activeRequests[request.messageId], request) &&
      !request.cancelled;

  void _finishRequest(_TranslationRequest request) {
    if (identical(_activeRequests[request.messageId], request)) {
      _activeRequests.remove(request.messageId);
    }
  }

  /// 翻译消息
  ///
  /// [message] 要翻译的消息
  /// [onTranslationStarted] 翻译开始回调（用户选择语言后、开始请求前调用）
  /// [onTranslationUpdate] 翻译更新回调（用于实时更新 UI）
  /// [onTranslationCleared] 翻译清除回调
  ///
  /// 返回翻译结果
  Future<TranslationResult> translateMessage({
    required ChatMessage message,
    required void Function() onTranslationStarted,
    required void Function(String translation) onTranslationUpdate,
    required void Function() onTranslationCleared,
  }) async {
    // Resolve a fresh context per call to avoid holding on to a stale BuildContext.
    final context = _getContext();
    final settings = context.read<SettingsProvider>();
    final assistant = context.read<AssistantProvider>().currentAssistant;
    final selection = _beginSelection(message.id);

    // 显示语言选择器
    final LanguageOption? language;
    try {
      language = await showLanguageSelector(context);
    } catch (_) {
      // Do not leave the request registered when the selector itself fails.
      _finishSelection(selection);
      rethrow;
    }
    if (language == null) {
      // Keep an already-running translation alive when the replacement
      // language picker is dismissed without a choice.
      _finishSelection(selection);
      return TranslationResult(type: TranslationResultType.cancelled);
    }

    if (!_isCurrentSelection(selection)) {
      return TranslationResult(type: TranslationResultType.cancelled);
    }
    _finishSelection(selection);
    final request = _beginRequest(message.id);

    // 检查是否选择清除翻译
    if (language.code == '__clear__') {
      try {
        onTranslationCleared();
        if (!_isCurrent(request)) {
          return TranslationResult(type: TranslationResultType.cancelled);
        }
        await _serializedMessageUpdate(
          message.id,
          request,
          () => chatService.updateMessage(message.id, translation: ''),
        );
        if (!_isCurrent(request)) {
          return TranslationResult(type: TranslationResultType.cancelled);
        }
        return TranslationResult(type: TranslationResultType.cleared);
      } finally {
        _finishRequest(request);
      }
    }

    // 获取翻译模型配置，回退顺序：翻译专用 -> 助手模型 -> 全局默认
    final translateProvider =
        settings.translateModelProvider ??
        assistant?.chatModelProvider ??
        settings.currentModelProvider;
    final translateModelId =
        settings.translateModelId ??
        assistant?.chatModelId ??
        settings.currentModelId;

    if (translateProvider == null || translateModelId == null) {
      _finishRequest(request);
      return TranslationResult(type: TranslationResultType.noModelConfigured);
    }

    try {
      // 用户已选择语言且模型配置有效，通知开始翻译
      if (_isCurrent(request)) onTranslationStarted();
      // 回调内可能取消或替换本请求（dispose / 新的翻译请求），重新确认
      if (!_isCurrent(request)) {
        return TranslationResult(type: TranslationResultType.cancelled);
      }

      // 提取要翻译的文本内容
      final textToTranslate = message.content;

      // 构建翻译 prompt
      String prompt = settings.translatePrompt
          .replaceAll('{source_text}', textToTranslate)
          .replaceAll('{target_lang}', language.displayName);

      // 创建翻译请求
      final provider = settings.getProviderConfig(translateProvider);
      final budget = settings.translateThinkingBudgetFor(
        assistant?.thinkingBudget,
      );

      final translation = await PlainTextCollector().collect(
        config: provider,
        modelId: translateModelId,
        messages: [
          {'role': 'user', 'content': prompt},
        ],
        thinkingBudget: budget,
        requestId: request.requestId,
        updateInterval: liveUpdateInterval,
        onAccumulated: (value) {
          if (_isCurrent(request)) onTranslationUpdate(value);
        },
      );

      if (!_isCurrent(request)) {
        return TranslationResult(type: TranslationResultType.cancelled);
      }

      // 保存最终翻译结果
      await _serializedMessageUpdate(
        message.id,
        request,
        () => chatService.updateMessage(message.id, translation: translation),
      );
      if (!_isCurrent(request)) {
        return TranslationResult(type: TranslationResultType.cancelled);
      }

      return TranslationResult(
        type: TranslationResultType.success,
        translation: translation,
      );
    } catch (e, st) {
      if (!_isCurrent(request)) {
        return TranslationResult(type: TranslationResultType.cancelled);
      }
      // The prompt embeds the user's message content; exceptions can echo
      // it, so only log in debug builds.
      if (kDebugMode) {
        debugPrint('TranslationService: translation failed: $e\n$st');
      }
      // 出错时清除翻译
      onTranslationCleared();
      if (!_isCurrent(request)) {
        return TranslationResult(type: TranslationResultType.cancelled);
      }
      await _serializedMessageUpdate(
        message.id,
        request,
        () => chatService.updateMessage(message.id, translation: ''),
      );
      if (!_isCurrent(request)) {
        return TranslationResult(type: TranslationResultType.cancelled);
      }

      return TranslationResult(
        type: TranslationResultType.error,
        errorMessage: e.toString(),
      );
    } finally {
      _finishRequest(request);
    }
  }

  /// Serializes per-message translation writes so a superseded request can
  /// never commit its stale text after a newer request's write.
  final Map<String, Future<void>> _messageWriteChains =
      <String, Future<void>>{};

  Future<void> _serializedMessageUpdate(
    String messageId,
    _TranslationRequest request,
    Future<void> Function() op,
  ) {
    final previous = _messageWriteChains[messageId] ?? Future<void>.value();
    final next = previous.catchError((_) {}).then<void>((_) {
      // A newer request can replace this request while it waits behind a
      // previous database write. Do not let the stale operation start after
      // that replacement.
      if (!_isCurrent(request)) return Future<void>.value();
      return op();
    });
    _messageWriteChains[messageId] = next.catchError((_) {});
    return next;
  }
}

class _TranslationRequest {
  _TranslationRequest({required this.messageId, required this.requestId});

  final String messageId;
  final String requestId;
  bool cancelled = false;
}
