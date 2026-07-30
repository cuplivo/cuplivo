import '../api/chat_api_service.dart';
import '../../providers/settings_provider.dart';

/// Immutable request shared by ordinary chat and group member streaming.
class ChatStreamExecutionRequest {
  const ChatStreamExecutionRequest({
    required this.config,
    required this.modelId,
    required this.messages,
    this.userMediaPaths = const <String>[],
    this.tools,
    this.onToolCall,
    this.thinkingBudget,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.extraHeaders,
    this.extraBody,
    this.stream = true,
    this.requestId,
    this.allowImagesApiRouting = true,
    this.ocrActive = false,
  });

  final ProviderConfig config;
  final String modelId;
  final List<Map<String, dynamic>> messages;
  final List<String> userMediaPaths;
  final List<Map<String, dynamic>>? tools;
  final ToolCallHandler? onToolCall;
  final int? thinkingBudget;
  final double? temperature;
  final double? topP;
  final int? maxTokens;
  final Map<String, String>? extraHeaders;
  final Map<String, dynamic>? extraBody;
  final bool stream;
  final String? requestId;
  final bool allowImagesApiRouting;
  final bool ocrActive;
}

class ChatStreamExecutor {
  const ChatStreamExecutor._();

  static Stream<ChatStreamChunk> open(ChatStreamExecutionRequest request) {
    return ChatApiService.sendMessageStream(
      config: request.config,
      modelId: request.modelId,
      messages: request.messages,
      userMediaPaths: request.userMediaPaths,
      thinkingBudget: request.thinkingBudget,
      temperature: request.temperature,
      topP: request.topP,
      maxTokens: request.maxTokens,
      tools: request.tools,
      onToolCall: request.onToolCall,
      extraHeaders: request.extraHeaders,
      extraBody: request.extraBody,
      stream: request.stream,
      requestId: request.requestId,
      allowImagesApiRouting: request.allowImagesApiRouting,
      ocrActive: request.ocrActive,
    );
  }
}
