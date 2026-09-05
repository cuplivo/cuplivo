import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/message_quote.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/instruction_injection.dart';
import '../../../core/models/world_book.dart';
import '../../../core/models/assistant_memory.dart';
import '../../../core/providers/memory_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/providers/workspace_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/chat/chat_context_transforms.dart';
import '../../../core/services/chat/document_text_extractor.dart';
import '../../../core/services/chat/prompt_transformer.dart';
import '../../../core/services/workspace/workspace_execution_context.dart';
import '../../../core/database/business_preferences.dart';
import '../../../core/services/instruction_injection_store.dart';
import '../../../core/services/world_book_store.dart';
import '../../../core/services/world_book_prompt_injector.dart';
import '../../../core/providers/instruction_injection_provider.dart';
import '../../../core/providers/world_book_provider.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/services/api/builtin_tools.dart';
import '../../../core/models/assistant_regex.dart';
import '../../../core/utils/multimodal_input_utils.dart';
import '../../model/utils/ocr_model_capability.dart';
import '../../../features/skills/skill_manager.dart';
import '../../../utils/assistant_regex.dart';
import '../../../utils/markdown_media_sanitizer.dart';
import '../../../utils/quote_plain_text.dart';

/// Service for building API messages from conversation state.
///
/// This service handles:
/// - Building API messages list from chat history
/// - Processing user messages (documents, OCR, templates)
/// - Injecting system prompts
/// - Injecting memory and recent chats context
/// - Injecting search prompts
/// - Injecting instruction prompts
/// - Applying context limits
/// - Inlining local images for model context
class MessageBuilderService {
  static const String internalMediaPathsKey = multimodalInternalMediaPathsKey;
  static const String _isPresetKey = '_isPreset';
  static const String _timestampKey = '_timestamp';

  MessageBuilderService({
    required this.chatService,
    required this.contextProvider,
    required BusinessPreferences preferences,
    this.ocrHandler,
    this.geminiThoughtSignatureProvider,
  }) : _worldBookStore = WorldBookStore.shared(preferences),
       _instructionInjectionStore = InstructionInjectionStore.shared(
         preferences,
       );

  final ChatService chatService;

  /// Build context (used for accessing providers via context.read)
  final BuildContext contextProvider;

  /// OCR handler for processing images (optional, injected from home_page)
  final Future<String?> Function(List<String> imagePaths)? ocrHandler;

  /// OCR text wrapper function
  String Function(String ocrText)? ocrTextWrapper;

  /// Handler to provide the Gemini thought signature payload (artifact JSON or
  /// legacy comment shell) for API calls; carried under an internal key so the
  /// message text stays clean for every provider.
  final String? Function(ChatMessage message)? geminiThoughtSignatureProvider;

  final WorldBookStore _worldBookStore;
  final InstructionInjectionStore _instructionInjectionStore;

  /// Cache for document text extraction to avoid re-reading files on every message
  /// Keyed by path, validated with (modified + size) to avoid stale reuse.
  final Map<String, _DocTextCacheEntry> _docTextCache =
      <String, _DocTextCacheEntry>{};

  /// Collapse message versions to show only selected version per group.
  List<ChatMessage> collapseVersions(
    List<ChatMessage> items,
    Map<String, int> versionSelections,
  ) {
    final Map<String, List<ChatMessage>> byGroup =
        <String, List<ChatMessage>>{};
    final List<String> order = <String>[];

    for (final m in items) {
      final gid = (m.groupId ?? m.id);
      final list = byGroup.putIfAbsent(gid, () {
        order.add(gid);
        return <ChatMessage>[];
      });
      list.add(m);
    }

    // Sort each group by version
    for (final e in byGroup.entries) {
      e.value.sort((a, b) => a.version.compareTo(b.version));
    }

    // Select the appropriate version from each group
    final out = <ChatMessage>[];
    for (final gid in order) {
      final vers = byGroup[gid]!;
      final sel = versionSelections[gid];
      final idx = (sel != null && sel >= 0 && sel < vers.length)
          ? sel
          : (vers.length - 1);
      out.add(vers[idx]);
    }

    return out;
  }

  /// Build API messages list from current conversation state.
  ///
  /// Applies truncation, version collapsing, and strips [image:] / [file:] markers.
  ///
  /// Contract: this returns an *intermediate* list. Every user message carries
  /// internal metadata keys ([_isPresetKey], [_timestampKey]) consumed downstream
  /// by [processUserMessagesForApi] to inject timestamps and skip presets.
  /// These keys are stripped before reaching the provider *only* inside
  /// [processUserMessagesForApi]. Do NOT forward the output of this method
  /// directly to an LLM provider — always pass it through
  /// [processUserMessagesForApi] first, otherwise the `_`-prefixed internal keys
  /// will leak into the request payload.
  List<Map<String, dynamic>> buildApiMessages({
    required List<ChatMessage> messages,
    required Map<String, int> versionSelections,
    required Conversation? currentConversation,
    bool includeToolMessages = false,
  }) {
    final tIndex = currentConversation?.truncateIndex ?? -1;
    final List<ChatMessage> sourceAll =
        (tIndex >= 0 && tIndex <= messages.length)
        ? messages.sublist(tIndex)
        : List.of(messages);
    final List<ChatMessage> source = collapseVersions(
      sourceAll,
      versionSelections,
    );

    // Resolve <reply-to> targets against the collapsed stream: the quote
    // points at a message row id; the resolved citation is the plain text of
    // that version (or the selected span). Unresolvable (deleted target) →
    // no prefix, display stub only (docs/adr/0046).
    final sourceById = <String, ChatMessage>{for (final m in source) m.id: m};

    final out = <Map<String, dynamic>>[];

    for (final m in source) {
      String? assistantReasoningContent;
      dynamic reasoningDetails;
      if (m.role == 'assistant') {
        assistantReasoningContent = _reasoningContentForToolContinuation(m);
        reasoningDetails = _reasoningDetailsForApi(m);
      }
      if (includeToolMessages && m.role == 'assistant') {
        final events = chatService.getToolEvents(m.id);
        if (events.isNotEmpty) {
          // Tool-call history is only valid once every call has a result.
          final hasPendingToolEvent = events.any((e) => e['content'] == null);
          if (!hasPendingToolEvent) {
            final calls = <Map<String, dynamic>>[];
            final toolMessages = <Map<String, dynamic>>[];

            for (int i = 0; i < events.length; i++) {
              final e = events[i];
              final name = (e['name'] ?? '').toString().trim();
              if (name.isEmpty) continue;
              final rawId = (e['id'] ?? '').toString().trim();
              final id = rawId.isNotEmpty
                  ? rawId
                  : 'call_${m.id.substring(0, m.id.length < 8 ? m.id.length : 8)}_$i';

              Map<String, dynamic> args = const <String, dynamic>{};
              final a = e['arguments'];
              if (a is Map) {
                args = a.map((k, v) => MapEntry(k.toString(), v));
              }
              String argumentsJson = '{}';
              try {
                argumentsJson = jsonEncode(args);
              } catch (_) {}

              calls.add({
                'id': id,
                'type': 'function',
                'function': {'name': name, 'arguments': argumentsJson},
                if (e['metadata'] is Map)
                  'metadata': (e['metadata'] as Map).cast<String, dynamic>(),
              });

              final c = e['content'];
              toolMessages.add({
                'role': 'tool',
                'name': name,
                'tool_call_id': id,
                'content': c.toString(),
                if (e['metadata'] is Map)
                  'metadata': (e['metadata'] as Map).cast<String, dynamic>(),
              });
            }

            if (calls.isNotEmpty) {
              final assistantToolMessage = <String, dynamic>{
                'role': 'assistant',
                'content': '\n\n',
                'tool_calls': calls,
              };
              if (assistantReasoningContent?.isNotEmpty == true) {
                assistantToolMessage['reasoning_content'] =
                    assistantReasoningContent;
              }
              out.add(assistantToolMessage);
              out.addAll(toolMessages);
            }
          }
        }
      }

      var content = m.content;
      if (content.isEmpty) continue;
      final isUser = m.role != 'assistant';
      if (isUser && content.trim().isNotEmpty) {
        final quote = m.quote;
        if (quote != null) {
          final quoteText = _replyToQuoteText(m, quote, sourceById);
          if (quoteText != null && quoteText.isNotEmpty) {
            content = '<reply-to>$quoteText</reply-to>\n\n$content';
          }
        }
      }
      final message = <String, dynamic>{
        'role': isUser ? 'user' : 'assistant',
        'content': content,
      };
      if (!isUser && geminiThoughtSignatureProvider != null) {
        final payload = geminiThoughtSignatureProvider!(m);
        if (payload != null && payload.trim().isNotEmpty) {
          message[multimodalInternalGeminiThoughtSignatureKey] = payload;
        }
      }
      if (isUser) {
        message[_isPresetKey] = m.isPreset;
        message[_timestampKey] = m.timestamp.toIso8601String();
      }
      if (assistantReasoningContent?.isNotEmpty == true) {
        message['reasoning_content'] = assistantReasoningContent;
      }
      if (reasoningDetails != null) {
        message['reasoning_details'] = reasoningDetails;
      }
      out.add(message);
    }

    return out;
  }

  /// `<reply-to>` plain text for [message]'s quote against the collapsed
  /// stream. Unresolvable target → null (no prefix; the UI shows the stub).
  /// Range slices are markdown-space ([start, end) into raw content) per
  /// docs/adr/0046; malformed out-of-range pairs degrade to full text.
  String? _replyToQuoteText(
    ChatMessage message,
    MessageQuote quote,
    Map<String, ChatMessage> sourceById,
  ) {
    final target = sourceById[quote.id];
    if (target == null) return null;
    final content = target.content;
    final start = quote.start;
    final end = quote.end;
    if (start != null && end != null) {
      final s = start < 0 ? 0 : start;
      final e = end > content.length ? content.length : end;
      if (s < e) return quotePlainText(content.substring(s, e));
    }
    return quotePlainText(content);
  }

  ChatMessage? _latestPersistedMessage(ChatMessage message) {
    final persisted = chatService.getMessages(message.conversationId);
    for (final candidate in persisted) {
      if (candidate.id == message.id) return candidate;
    }
    return null;
  }

  /// Extract persisted vendor reasoning details (OpenRouter-style
  /// `reasoning_details`, may carry thinking signatures) so they can be
  /// echoed back to the provider on later turns.
  dynamic _reasoningDetailsForApi(ChatMessage message) {
    dynamic pick(ChatMessage candidate) {
      final raw = (candidate.reasoningSegmentsJson ?? '').trim();
      if (raw.isEmpty) return null;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) return null;
        final details = decoded['reasoningDetails'];
        if (details is List && details.isNotEmpty) return details;
      } catch (_) {}
      return null;
    }

    final fromMessage = pick(message);
    if (fromMessage != null) return fromMessage;

    final persisted = _latestPersistedMessage(message);
    if (persisted == null) return null;
    return pick(persisted);
  }

  String _reasoningContentForToolContinuation(ChatMessage message) {
    String pick(ChatMessage candidate) {
      final direct = (candidate.reasoningText ?? '').trim();
      if (direct.isNotEmpty) return direct;

      final raw = (candidate.reasoningSegmentsJson ?? '').trim();
      if (raw.isEmpty) return '';
      try {
        final decoded = jsonDecode(raw);
        final segmentsRaw = switch (decoded) {
          Map<String, dynamic> map => map['segments'],
          List<dynamic> list => list,
          _ => null,
        };
        if (segmentsRaw is! List) return '';
        final parts = <String>[];
        for (final item in segmentsRaw) {
          if (item is! Map) continue;
          final text = (item['text'] ?? '').toString().trim();
          if (text.isNotEmpty) parts.add(text);
        }
        return parts.join('\n').trim();
      } catch (_) {
        return '';
      }
    }

    final fromMessage = pick(message);
    if (fromMessage.isNotEmpty) return fromMessage;

    final persisted = _latestPersistedMessage(message);
    if (persisted == null) return '';
    return pick(persisted);
  }

  /// Parse input data from raw message content (extracts images and documents).
  ChatInputData parseInputFromRaw(
    String raw, {
    bool includeMediaFilePathsAsImages = true,
  }) {
    final imgRe = RegExp(r"\[image:(.+?)\]");
    final fileRe = RegExp(r"\[file:(.+?)\|(.+?)\|(.+?)\]");
    final images = <String>[];
    final docs = <DocumentAttachment>[];
    final buffer = StringBuffer();
    int idx = 0;
    while (idx < raw.length) {
      final imgMatch = imgRe.matchAsPrefix(raw, idx);
      final fileMatch = fileRe.matchAsPrefix(raw, idx);
      if (imgMatch != null) {
        final p = imgMatch.group(1)?.trim();
        if (p != null && p.isNotEmpty) images.add(p);
        idx = imgMatch.end;
        continue;
      }
      if (fileMatch != null) {
        final path = fileMatch.group(1)?.trim() ?? '';
        final name = fileMatch.group(2)?.trim() ?? 'file';
        final mime = fileMatch.group(3)?.trim() ?? 'text/plain';
        final doc = DocumentAttachment(path: path, fileName: name, mime: mime);
        docs.add(doc);
        // Video/audio attachments need to be tracked in imagePaths so downstream
        // API builders can route them as media (addImageUrl/addVideoUrl).
        // Office documents are NOT added here: they are handled separately via
        // _resolveFileProcessingMode → directPaths in processUserMessagesForApi.
        final effectiveMime = _effectiveAttachmentMime(doc);
        if (includeMediaFilePathsAsImages &&
            path.isNotEmpty &&
            (isVideoMime(effectiveMime) || isAudioMime(effectiveMime))) {
          images.add(path);
        }
        idx = fileMatch.end;
        continue;
      }
      buffer.write(raw[idx]);
      idx++;
    }
    return ChatInputData(
      text: buffer.toString().trim(),
      imagePaths: images,
      documents: docs,
    );
  }

  String _effectiveAttachmentMime(DocumentAttachment attachment) {
    return resolveDocumentAttachmentMime(attachment);
  }

  /// Resolve the processing mode for a MIME type based on assistant config.
  String _resolveFileProcessingMode(String mime, {Assistant? assistant}) {
    final lower = mime.toLowerCase();
    if (lower == 'application/pdf') {
      return assistant?.pdfMode ?? 'extract';
    }
    if (lower ==
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document') {
      return assistant?.docxMode ?? 'extract';
    }
    if (isOfficeDocumentMime(lower)) {
      return assistant?.otherOfficeMode ?? 'direct';
    }
    return 'extract';
  }

  /// Process user messages in apiMessages: extract documents, apply OCR, inject file prompts.
  ///
  /// Returns the image paths from the last user message (for API call).
  ///
  /// Boundary: this is the sole point where internal `_`-prefixed keys
  /// ([_isPresetKey], [_timestampKey]) attached by [buildApiMessages] are
  /// consumed and stripped. After this method returns, the list is safe to send
  /// to a provider.
  Future<List<String>> processUserMessagesForApi(
    List<Map<String, dynamic>> apiMessages,
    SettingsProvider settings,
    Assistant? assistant, {
    required String providerKey,
    required String modelId,
  }) async {
    final bool ocrActive = resolveOcrActive(
      settings: settings,
      assistant: assistant,
      providerKey: providerKey,
      modelId: modelId,
    );

    List<String>? lastUserImagePaths;

    // Find last user message index
    int lastUserIdx = -1;
    for (int i = apiMessages.length - 1; i >= 0; i--) {
      if (apiMessages[i]['role'] == 'user') {
        lastUserIdx = i;
        break;
      }
    }

    Future<String?> readDocument(DocumentAttachment d) async {
      // Use file stat to detect content changes without hashing.
      FileStat? stat;
      try {
        stat = await File(d.path).stat();
      } catch (_) {
        stat = null;
      }
      if (stat != null) {
        final cached = _docTextCache[d.path];
        if (cached != null &&
            cached.modifiedMs == stat.modified.millisecondsSinceEpoch &&
            cached.size == stat.size) {
          return cached.text;
        }
      }
      try {
        final text = await DocumentTextExtractor.extract(
          path: d.path,
          mime: d.mime,
        );
        // Cache only when stat is available; otherwise avoid staleness.
        if (stat != null) {
          _docTextCache[d.path] = _DocTextCacheEntry(
            text: text,
            modifiedMs: stat.modified.millisecondsSinceEpoch,
            size: stat.size,
          );
        }
        return text;
      } catch (_) {
        if (stat != null) {
          _docTextCache[d.path] = _DocTextCacheEntry(
            text: null,
            modifiedMs: stat.modified.millisecondsSinceEpoch,
            size: stat.size,
          );
        }
        return null;
      }
    }

    for (int i = 0; i < apiMessages.length; i++) {
      if (apiMessages[i]['role'] != 'user') continue;
      final rawUser = (apiMessages[i]['content'] ?? '').toString();
      final parsedUser = parseInputFromRaw(rawUser);
      final videoPaths = <String>{
        for (final d in parsedUser.documents)
          if (isVideoMime(_effectiveAttachmentMime(d))) d.path.trim(),
      }..removeWhere((p) => p.isEmpty);
      final audioPaths = <String>{
        for (final d in parsedUser.documents)
          if (isAudioMime(_effectiveAttachmentMime(d))) d.path.trim(),
      }..removeWhere((p) => p.isEmpty);
      // Direct-upload paths: office/pdf documents set to 'direct' mode.
      final directPaths = <String>{
        for (final d in parsedUser.documents)
          if (_resolveFileProcessingMode(
                _effectiveAttachmentMime(d),
                assistant: assistant,
              ) ==
              'direct')
            d.path.trim(),
      }..removeWhere((p) => p.isEmpty);

      final messageMediaPaths = <String>{
        for (final p in parsedUser.imagePaths.map((p) => p.trim()))
          if (p.isNotEmpty &&
              (!ocrActive ||
                  videoPaths.contains(p) ||
                  audioPaths.contains(p) ||
                  directPaths.contains(p)))
            p,
        // Include direct-mode document paths as media (e.g. PDF in direct mode).
        ...directPaths,
      }.toList(growable: false);
      if (messageMediaPaths.isEmpty) {
        apiMessages[i].remove(internalMediaPathsKey);
      } else {
        apiMessages[i][internalMediaPathsKey] = messageMediaPaths;
      }

      // Capture image paths from last user message
      if (i == lastUserIdx &&
          lastUserImagePaths == null &&
          parsedUser.imagePaths.isNotEmpty) {
        lastUserImagePaths = List<String>.of(parsedUser.imagePaths);
      }

      final inlineImagePaths = parsedUser.imagePaths
          .map((p) => p.trim())
          .where(
            (p) =>
                p.isNotEmpty &&
                !videoPaths.contains(p) &&
                !audioPaths.contains(p) &&
                !directPaths.contains(p),
          )
          .toList(growable: false);

      // Apply replace-only regexes at send-time on user text (exclude markers).
      final replacedUserText = applyAssistantRegexes(
        parsedUser.text,
        assistant: assistant,
        scope: AssistantRegexScope.user,
        target: AssistantRegexTransformTarget.send,
      );

      final imageMarkers = (!ocrActive && inlineImagePaths.isNotEmpty)
          ? inlineImagePaths.map((p) => '\n[image:$p]').join()
          : '';
      final cleanedUser = (replacedUserText + imageMarkers).trim();

      final filePrompts = StringBuffer();
      for (final d in parsedUser.documents) {
        final effectiveMime = _effectiveAttachmentMime(d);
        final mode = _resolveFileProcessingMode(
          effectiveMime,
          assistant: assistant,
        );
        // Skip non-extract modes: direct (sent as media) and discard (excluded).
        if (mode != 'extract') continue;
        // Video and audio are always sent as media, not extracted.
        if (isVideoMime(effectiveMime) || isAudioMime(effectiveMime)) {
          continue;
        }
        final text = await readDocument(d);
        if (text == null || text.trim().isEmpty) continue;
        filePrompts.writeln('## user sent a file: ${d.fileName}');
        filePrompts.writeln('<content>');
        filePrompts.writeln('```');
        filePrompts.writeln(text);
        filePrompts.writeln('```');
        filePrompts.writeln('</content>');
        filePrompts.writeln();
      }

      String merged = (filePrompts.toString() + cleanedUser).trim();

      if (ocrActive && ocrHandler != null) {
        final ocrTargets = parsedUser.imagePaths
            .map((p) => p.trim())
            .where(
              (p) =>
                  p.isNotEmpty &&
                  !videoPaths.contains(p) &&
                  !audioPaths.contains(p) &&
                  !directPaths.contains(p),
            )
            .toSet()
            .toList();
        if (ocrTargets.isNotEmpty) {
          final ocrText = await ocrHandler!(ocrTargets);
          if (ocrText != null && ocrText.trim().isNotEmpty) {
            final wrapped = ocrTextWrapper != null
                ? ocrTextWrapper!(ocrText)
                : _defaultWrapOcrBlock(ocrText);
            merged = (wrapped + merged).trim();
          }
        }
      }

      apiMessages[i]['content'] = merged.isEmpty ? cleanedUser : merged;

      // Append timestamp when time injection is enabled (skip presets)
      if (assistant?.enableTimeInjection == true &&
          apiMessages[i][_isPresetKey] != true) {
        final tsStr = apiMessages[i][_timestampKey] as String?;
        if (tsStr != null) {
          final ts = DateTime.tryParse(tsStr);
          if (ts != null) {
            apiMessages[i]['content'] = ChatContextTransforms.appendTimestamp(
              (apiMessages[i]['content'] ?? '').toString(),
              ts,
            );
          }
        }
      }
      // Strip internal metadata keys after consumption so they never leak to
      // the provider. Both keys are only read above; remove unconditionally.
      apiMessages[i].remove(_isPresetKey);
      apiMessages[i].remove(_timestampKey);
    }

    // Apply message template to last user message (skipped when time injection active)
    if (lastUserIdx != -1 && (assistant?.enableTimeInjection != true)) {
      final userText = (apiMessages[lastUserIdx]['content'] ?? '').toString();
      final templ =
          (assistant?.messageTemplate ?? '{{ message }}').trim().isEmpty
          ? '{{ message }}'
          : (assistant!.messageTemplate);
      final templated = PromptTransformer.applyMessageTemplate(
        templ,
        role: 'user',
        message: userText,
        now: DateTime.now(),
      );
      apiMessages[lastUserIdx]['content'] = templated;
    }

    return lastUserImagePaths ?? <String>[];
  }

  /// Default OCR text wrapper
  String _defaultWrapOcrBlock(String ocrText) {
    final buf = StringBuffer();
    buf.writeln(
      "The image_file_ocr tag contains a description of an image that the user uploaded to you, not the user's prompt.",
    );
    buf.writeln('<image_file_ocr>');
    buf.writeln(ocrText.trim());
    buf.writeln('</image_file_ocr>');
    buf.writeln();
    return buf.toString();
  }

  /// Inject system prompt into apiMessages.
  void injectSystemPrompt(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant,
    String modelId,
  ) {
    if ((assistant?.systemPrompt.trim().isNotEmpty ?? false)) {
      final vars = PromptTransformer.buildPlaceholders(
        context: contextProvider,
        assistant: assistant!,
        modelId: modelId,
        modelName: modelId,
        userNickname: contextProvider.read<UserProvider>().name,
      );
      final sys = PromptTransformer.replacePlaceholders(
        assistant.systemPrompt,
        vars,
      );
      apiMessages.insert(0, {'role': 'system', 'content': sys});
    }
  }

  void injectWorkspacePrompt(
    List<Map<String, dynamic>> apiMessages,
    String? prompt,
  ) {
    if (prompt == null || prompt.trim().isEmpty) return;
    _appendToSystemMessage(apiMessages, prompt);
  }

  /// Inject memory prompts and recent chats reference into apiMessages.
  Future<void> injectMemoryAndRecentChats(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant, {
    String? currentConversationId,
  }) async {
    try {
      if (assistant?.enableMemory == true) {
        final mp = contextProvider.read<MemoryProvider>();
        await mp.initialize();
        final mems = mp.getForAssistant(assistant!.id);
        final now = DateTime.now();
        final buf = StringBuffer();
        if (assistant.memoryMode != 'tool') {
          buf.writeln('## Memories');
          buf.writeln(
            'These are memories that you can reference in the future conversations.',
          );
          buf.writeln(AssistantMemory.buildMemoryXml(mems));
          // Fixed header for Memory Tool (always included)
          buf.writeln('''
## Memory Tool
You are a stateless language model without persistent memory. To retain information, use **memory tools**.
You can use `create_memory`, `edit_memory`, and `delete_memory` tools to create, update, or delete memories.
- If no relevant information exists in memories, use create_memory to create a new record.
- If a relevant record already exists, use edit_memory to update its content.
- If a memory is outdated or no longer useful, use delete_memory to remove it.
These memories are automatically included in future conversation contexts within the <memories> tag.
''');
        }
        // Customizable record prompt from assistant settings
        final recordPrompt =
            (assistant.memoryRecordPrompt.isNotEmpty
                    ? assistant.memoryRecordPrompt
                    : Assistant.defaultMemoryRecordPrompt)
                .replaceAll('{current_hour}', _formatCurrentHour(now))
                .replaceAll('{current_date}', _formatCurrentDate(now))
                .replaceAll('{current_datetime}', _formatCurrentDatetime(now));
        buf.writeln(recordPrompt);
        _appendToSystemMessage(apiMessages, buf.toString());
      }
      if (assistant?.enableRecentChatsReference == true) {
        final relevantChats = ChatContextTransforms.selectRecentChats(
          chatService.getAllConversations(),
          assistantId: assistant!.id,
          currentConversationId: currentConversationId,
        );
        if (relevantChats.isNotEmpty) {
          _appendToSystemMessage(
            apiMessages,
            ChatContextTransforms.buildRecentChatsBlock(relevantChats),
          );
        }
      }
    } catch (_) {}
  }

  String _formatCurrentHour(DateTime now) {
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')} (hrs)';
  }

  String _formatCurrentDate(DateTime now) {
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  String _formatCurrentDatetime(DateTime now) {
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
  }

  /// Inject `<time-note>` into the system message when time injection is enabled.
  void injectTimeNote(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant,
  ) {
    if (assistant?.enableTimeInjection == true) {
      ChatContextTransforms.injectTimeNote(apiMessages);
    }
  }

  /// Inject search tool usage prompt into apiMessages.
  void injectSearchPrompt(
    List<Map<String, dynamic>> apiMessages,
    SettingsProvider settings,
    Assistant? assistant,
    bool hasBuiltInSearch,
  ) {
    if (assistant?.searchEnabled == true && !hasBuiltInSearch) {
      // Deprecated. Moved to tool description.
    }
  }

  /// Inject instruction injection prompts into apiMessages.
  Future<void> injectInstructionPrompts(
    List<Map<String, dynamic>> apiMessages,
    String? assistantId,
  ) async {
    try {
      List<InstructionInjection> actives = const <InstructionInjection>[];
      try {
        final ip = contextProvider.read<InstructionInjectionProvider>();
        actives = ip.activesFor(assistantId);
        if (actives.isEmpty) {
          actives = await _instructionInjectionStore.getActives(
            assistantId: assistantId,
          );
        }
      } catch (_) {
        actives = await _instructionInjectionStore.getActives(
          assistantId: assistantId,
        );
      }
      final prompts = actives
          .map((e) => e.prompt.trim())
          .where((p) => p.isNotEmpty)
          .toList(growable: false);
      if (prompts.isNotEmpty) {
        final lp = prompts.join('\n\n');
        _appendToSystemMessage(apiMessages, lp);
      }
    } catch (_) {}
  }

  /// Inject project-level AGENTS.md instructions for the effective workspace
  /// directory. A read failure aborts this generation so project instructions
  /// are never only partially applied.
  Future<void> injectWorkspaceAgentsMdInstructions(
    List<Map<String, dynamic>> apiMessages, {
    required Assistant? assistant,
    required WorkspaceExecutionContext? workspaceExecutionContext,
  }) async {
    if (assistant?.autoLoadAgentsMd != true ||
        workspaceExecutionContext == null) {
      return;
    }

    try {
      final instructions = await loadWorkspaceAgentsMdInstructions(
        context: workspaceExecutionContext,
        workspaces: contextProvider.read<WorkspaceProvider>(),
      );
      if (instructions != null) {
        _appendToSystemMessage(apiMessages, instructions);
      }
    } on WorkspaceAgentsMdLoadException catch (error, stackTrace) {
      debugPrint(
        'Failed to load workspace AGENTS.md instructions: '
        '${error.message}\n$stackTrace',
      );
      rethrow;
    } catch (error, stackTrace) {
      debugPrint(
        'Unexpected workspace AGENTS.md loading failure: '
        '$error\n$stackTrace',
      );
      throw WorkspaceAgentsMdLoadException(error.toString());
    }
  }

  /// Inject available skill list (metadata only) into apiMessages.
  Future<void> injectSkillListPrompt(
    List<Map<String, dynamic>> apiMessages,
    String? assistantId,
  ) async {
    try {
      List<String> skillIds;
      try {
        final ap = contextProvider.read<AssistantProvider>();
        final a = (assistantId != null)
            ? ap.getById(assistantId)
            : ap.currentAssistant;
        if (a == null) return;
        skillIds = a.skillIds;
      } catch (_) {
        return;
      }
      if (skillIds.isEmpty) return;

      final targetSet = skillIds.toSet();
      final allSkills = await SkillManager.listSkills();
      final matched = allSkills
          .where((s) => targetSet.contains(s.name) && s.description.isNotEmpty)
          .toList(growable: false);
      if (matched.isEmpty) return;

      final sb = StringBuffer();
      sb.writeln('<available_skills>');
      for (final skill in matched) {
        sb.writeln('  <skill>');
        sb.writeln('    <name>${skill.name}</name>');
        sb.writeln('    <description>${skill.description}</description>');
        sb.writeln('  </skill>');
      }
      sb.write('</available_skills>');
      _appendToSystemMessage(apiMessages, sb.toString());
    } catch (_) {}
  }

  /// Inject world book (lorebook) entries into apiMessages.
  Future<void> injectWorldBookPrompts(
    List<Map<String, dynamic>> apiMessages,
    String? assistantId,
  ) async {
    try {
      List<WorldBook> all = const <WorldBook>[];
      List<String> activeBookIds = const <String>[];

      try {
        final wb = contextProvider.read<WorldBookProvider>();
        all = wb.books;
        activeBookIds = wb.activeBookIdsFor(assistantId);
        if (all.isEmpty) all = await _worldBookStore.getAll();
        if (activeBookIds.isEmpty) {
          activeBookIds = await _worldBookStore.getActiveIds(
            assistantId: assistantId,
          );
        }
      } catch (_) {
        all = await _worldBookStore.getAll();
        activeBookIds = await _worldBookStore.getActiveIds(
          assistantId: assistantId,
        );
      }

      if (all.isEmpty || activeBookIds.isEmpty) return;
      WorldBookPromptInjector.inject(
        messages: apiMessages,
        books: all,
        activeBookIds: activeBookIds,
      );
    } catch (_) {}
  }

  /// Helper to append content to the system message (or create one if missing).
  void _appendToSystemMessage(
    List<Map<String, dynamic>> apiMessages,
    String content,
  ) {
    if (apiMessages.isNotEmpty && apiMessages.first['role'] == 'system') {
      apiMessages[0]['content'] =
          '${(apiMessages[0]['content'] ?? '') as String}\n\n$content';
    } else {
      apiMessages.insert(0, {'role': 'system', 'content': content});
    }
  }

  /// Apply context message limit based on assistant settings.
  void applyContextLimit(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant,
  ) {
    ChatContextTransforms.applyMessageLimit(apiMessages, assistant);
  }

  /// Convert local Markdown image links to inline base64 for model context.
  Future<void> inlineLocalImages(List<Map<String, dynamic>> apiMessages) async {
    for (int i = 0; i < apiMessages.length; i++) {
      final s = (apiMessages[i]['content'] ?? '').toString();
      if (s.isNotEmpty) {
        apiMessages[i]['content'] =
            await MarkdownMediaSanitizer.inlineLocalImagesToBase64(s);
      }
    }
  }

  /// Check if built-in search is enabled for the given provider/model.
  bool hasBuiltInSearch(
    SettingsProvider settings,
    String providerKey,
    String modelId,
  ) {
    try {
      final cfg = settings.getProviderConfig(providerKey);
      return BuiltInToolsHelper.isBuiltInSearchEnabled(
        cfg: cfg,
        modelId: modelId,
      );
    } catch (_) {
      return false;
    }
  }
}

class _DocTextCacheEntry {
  const _DocTextCacheEntry({
    required this.text,
    required this.modifiedMs,
    required this.size,
  });

  final String? text;
  final int modifiedMs;
  final int size;
}
