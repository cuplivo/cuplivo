import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import '../database/business_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../utils/app_directories.dart';
import '../../utils/assistant_regex.dart';
import '../models/assistant.dart';
import '../models/assistant_regex.dart';
import '../models/auto_retry_options.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../providers/settings_provider.dart';
import 'api/chat_api_service.dart';
import 'api/plain_text_collector.dart';
import 'chat/chat_context_transforms.dart';
import 'chat/chat_service.dart';
import 'chat/prompt_transformer.dart';
import 'instruction_injection_store.dart';
import 'logging/flutter_logger.dart';
import 'memory_store.dart';
import 'proactive_care_decision_tools.dart';
import 'proactive_care_service.dart';
import 'world_book_prompt_injector.dart';
import 'world_book_store.dart';

const String _logTag = 'ProactiveCareFlow';

/// Stream source signature for the decision flow (injectable for tests).
/// Subset of [ChatApiService.sendMessageStream], same idea as
/// DirectorStreamSender.
typedef ProactiveCareDecisionSender =
    Stream<ChatStreamChunk> Function({
      required ProviderConfig config,
      required String modelId,
      required List<Map<String, dynamic>> messages,
      List<Map<String, dynamic>>? tools,
      ToolCallHandler? onToolCall,
      int? thinkingBudget,
      double? temperature,
      double? topP,
      int? maxTokens,
      bool stream,
      String? requestId,
      AutoRetryOptions? retryOverride,
    });

/// Snapshot of localized strings needed by the proactive care background
/// isolate, which has no BuildContext / AppLocalizations. The main isolate
/// saves it on every app start (see main.dart), so by the time an alarm can
/// fire the snapshot reflects the user's UI language.
class ProactiveCareL10nSnapshot {
  const ProactiveCareL10nSnapshot({
    required this.defaultConversationTitle,
    required this.carePromptDefault,
    required this.decisionPromptDefault,
    required this.failureNotificationBody,
  });

  static const String _prefsKey = 'proactive_care_l10n_v1';

  final String defaultConversationTitle;
  final String carePromptDefault;
  final String decisionPromptDefault;
  final String failureNotificationBody;
}

/// Resolved provider/model for a proactive care request.
class ProactiveCareModelConfig {
  const ProactiveCareModelConfig({
    required this.config,
    required this.providerKey,
    required this.modelId,
  });

  final ProviderConfig config;
  final String providerKey;
  final String modelId;
}

/// Shared logic for the proactive care message ("Ta的来信") sent when the
/// scheduled care time arrives.
///
/// Everything here is headless (no BuildContext): the same code path runs in
/// the main isolate (app alive) and in the alarm background isolate (app
/// killed). Only data loading and persistence differ between the two paths:
/// the main isolate uses providers + ChatService, the background isolate uses
/// SQLite via [ProactiveCareHeadlessChatStore].
///
/// The decision flow (Pipeline ①) uses the same transport as normal chat
/// ([ChatApiService.sendMessageStream]) with provider-default
/// `tool_choice: auto` (not `required`), so DeepSeek and other
/// OpenAI-compatible hosts that reject forced tools still work.
class ProactiveCareMessageFlow {
  ProactiveCareMessageFlow({required BusinessPreferences preferences})
    : _preferences = preferences,
      _memoryStore = MemoryStore.shared(preferences),
      _worldBookStore = WorldBookStore.shared(preferences),
      _instructionInjectionStore = InstructionInjectionStore.shared(
        preferences,
      );

  final BusinessPreferences _preferences;
  final MemoryStore _memoryStore;
  final WorldBookStore _worldBookStore;
  final InstructionInjectionStore _instructionInjectionStore;
  Future<void> saveL10nSnapshot({
    required String defaultConversationTitle,
    required String carePromptDefault,
    required String decisionPromptDefault,
    required String failureNotificationBody,
  }) async {
    await _preferences.setString(
      ProactiveCareL10nSnapshot._prefsKey,
      jsonEncode(<String, String>{
        'defaultConversationTitle': defaultConversationTitle,
        'carePromptDefault': carePromptDefault,
        'decisionPromptDefault': decisionPromptDefault,
        'failureNotificationBody': failureNotificationBody,
      }),
    );
  }

  Future<ProactiveCareL10nSnapshot?> loadL10nSnapshot() async {
    try {
      final raw = _preferences.getString(ProactiveCareL10nSnapshot._prefsKey);
      if (raw == null || raw.isEmpty) return null;
      final map = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return ProactiveCareL10nSnapshot(
        defaultConversationTitle:
            (map['defaultConversationTitle'] as String?) ?? '',
        carePromptDefault: (map['carePromptDefault'] as String?) ?? '',
        decisionPromptDefault: (map['decisionPromptDefault'] as String?) ?? '',
        failureNotificationBody:
            (map['failureNotificationBody'] as String?) ?? '',
      );
    } catch (e) {
      FlutterLogger.log('L10n snapshot load failed: $e', tag: _logTag);
      return null;
    }
  }

  // SharedPreferences keys owned by other classes that keep them private.
  // They are stable v1 keys; keep in sync with SettingsProvider.
  static const String _selectedModelPrefsKey = 'selected_model_v1';
  static const String _providerConfigsPrefsKey = 'provider_configs_v1';
  // Keep in sync with UserProvider.
  static const String _userNamePrefsKey = 'user_name';

  /// Loads [assistantId] from SQLite (background isolate path).
  static Future<Assistant?> loadAssistantFromDb(String assistantId) async {
    try {
      return await ProactiveCareHeadlessChatStore.loadAssistantFor(assistantId);
    } catch (e) {
      FlutterLogger.log('Load assistant from DB failed: $e', tag: _logTag);
    }
    return null;
  }

  /// Persists a new next-care time for [assistantId] in SQLite (background
  /// isolate path; the app process is dead, so there is no concurrent writer).
  static Future<bool> updateAssistantNextCareTimeInDb(
    String assistantId,
    DateTime nextCareTime,
  ) async {
    try {
      await ProactiveCareHeadlessChatStore.updateNextCareTime(
        assistantId,
        nextCareTime,
      );
      return true;
    } catch (e) {
      FlutterLogger.log(
        'Persist next care time to DB failed: $e',
        tag: _logTag,
      );
      return false;
    }
  }

  /// Resolves the chat model for [assistant] from SharedPreferences:
  /// assistant-specific model first, then the globally selected model
  /// (mirrors the decision flow in HomeViewModel).
  Future<ProactiveCareModelConfig?> loadModelConfigFromPrefs(
    Assistant assistant,
  ) async {
    final prefs = _preferences;
    String? provKey = assistant.chatModelProvider;
    String? modelId = assistant.chatModelId;
    if (provKey == null || modelId == null) {
      final sel = prefs.getString(_selectedModelPrefsKey);
      if (sel != null && sel.contains('::')) {
        final parts = sel.split('::');
        if (parts.length >= 2) {
          provKey ??= parts[0];
          modelId ??= parts.sublist(1).join('::');
        }
      }
    }
    if (provKey == null || modelId == null) return null;

    ProviderConfig? cfg;
    try {
      final cfgStr = prefs.getString(_providerConfigsPrefsKey);
      if (cfgStr != null && cfgStr.isNotEmpty) {
        final raw = jsonDecode(cfgStr) as Map<String, dynamic>;
        final entry = raw[provKey];
        if (entry is Map) {
          cfg = ProviderConfig.fromJson(entry.cast<String, dynamic>());
        }
      }
    } catch (e) {
      FlutterLogger.log('Provider configs decode failed: $e', tag: _logTag);
    }
    cfg ??= ProviderConfig.defaultsFor(provKey);
    return ProactiveCareModelConfig(
      config: cfg,
      providerKey: provKey,
      modelId: modelId,
    );
  }

  /// Resolves the proactive care decision model from SharedPreferences.
  /// Falls back to the chat model if no dedicated decision model is set.
  Future<ProactiveCareModelConfig?> loadDecisionModelConfigFromPrefs(
    Assistant assistant,
  ) async {
    final prefs = _preferences;
    final sel = prefs.getString('proactive_care_decision_model_v1');
    if (sel != null && sel.contains('::')) {
      final parts = sel.split('::');
      if (parts.length >= 2) {
        final provKey = parts[0];
        final modelId = parts.sublist(1).join('::');
        ProviderConfig? cfg;
        try {
          final cfgStr = prefs.getString(_providerConfigsPrefsKey);
          if (cfgStr != null && cfgStr.isNotEmpty) {
            final raw = jsonDecode(cfgStr) as Map<String, dynamic>;
            final entry = raw[provKey];
            if (entry is Map) {
              cfg = ProviderConfig.fromJson(entry.cast<String, dynamic>());
            }
          }
        } catch (e) {
          debugPrint(
            '[ProactiveCare] Decision provider config decode failed: $e',
          );
        }
        cfg ??= ProviderConfig.defaultsFor(provKey);
        return ProactiveCareModelConfig(
          config: cfg,
          providerKey: provKey,
          modelId: modelId,
        );
      }
    }
    // Fallback to chat model
    return loadModelConfigFromPrefs(assistant);
  }

  /// Loads the user nickname for system prompt placeholders (background
  /// path). 'User' mirrors UserProvider's built-in default.
  Future<String> loadUserNicknameFromPrefs() async {
    try {
      final prefs = _preferences;
      final n = prefs.getString(_userNamePrefsKey);
      if (n != null && n.isNotEmpty) return n;
    } catch (e) {
      debugPrint('[ProactiveCare] User nickname load failed: $e');
    }
    return 'User';
  }

  /// Loads the global thinking budget from SharedPreferences for use in
  /// background isolates where SettingsProvider is unavailable.
  Future<int?> loadThinkingBudgetFromPrefs() async {
    try {
      final prefs = _preferences;
      return prefs.getInt('thinking_budget_v1');
    } catch (e) {
      debugPrint('[ProactiveCare] Thinking budget load failed: $e');
    }
    return null;
  }

  /// Collapses message versions, keeping the selected (or latest) version per
  /// group. Same semantics as ChatService.collapseMessageVersions.
  @visibleForTesting
  static List<ChatMessage> collapseMessageVersions(
    List<ChatMessage> items,
    Map<String, int> versionSelections,
  ) {
    return ChatService.collapseMessageVersions(items, versionSelections);
  }

  /// Builds the plain-text LLM history for [conversation]: collapsed versions,
  /// truncateIndex applied, and only completed non-empty user/assistant turns.
  /// Smart-time timestamps follow [Assistant.enableTimeInjection]. Send-only
  /// assistant regexes are applied only when [applySendRegexes] is true.
  List<Map<String, dynamic>> buildHistory({
    required Conversation conversation,
    required List<ChatMessage> messages,
    required Assistant assistant,
    required bool applySendRegexes,
  }) {
    final collapsed = collapseMessageVersions(
      messages,
      conversation.versionSelections,
    );
    final tIndex = conversation.truncateIndex;
    final collapsedSkip = ChatService.rawToCollapsedSkip(
      rawMessages: messages,
      collapsedMessages: collapsed,
      truncateIndex: tIndex,
    );
    final effective = collapsedSkip > 0
        ? collapsed.sublist(collapsedSkip)
        : collapsed;
    final history = <Map<String, dynamic>>[];
    for (final message in effective) {
      if ((message.role != 'user' && message.role != 'assistant') ||
          message.isStreaming ||
          message.content.trim().isEmpty) {
        continue;
      }

      var content = message.content;
      if (applySendRegexes) {
        String applyRegexes(String text) => applyAssistantRegexes(
          text,
          assistant: assistant,
          scope: message.role == 'assistant'
              ? AssistantRegexScope.assistant
              : AssistantRegexScope.user,
          target: AssistantRegexTransformTarget.send,
        );
        content = message.role == 'user'
            ? ChatContextTransforms.transformTextPreservingAttachmentMarkers(
                content,
                applyRegexes,
              )
            : applyRegexes(content);
      }
      if (message.role == 'user' &&
          assistant.enableTimeInjection &&
          !message.isPreset) {
        content = ChatContextTransforms.appendTimestamp(
          content,
          message.timestamp,
        );
      }
      history.add({'role': message.role, 'content': content});
    }
    return history;
  }

  /// System prompt placeholders without a BuildContext: locale comes from
  /// Platform.localeName instead of Localizations (otherwise mirrors
  /// PromptTransformer.buildPlaceholders).
  @visibleForTesting
  Map<String, String> buildHeadlessPlaceholders({
    required Assistant assistant,
    required String modelId,
    required String userNickname,
    required DateTime now,
  }) {
    final date =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final os = Platform.operatingSystem;
    final osv = Platform.operatingSystemVersion;
    return <String, String>{
      '{cur_date}': date,
      '{cur_time}': time,
      '{cur_datetime}': '$date $time',
      '{model_id}': modelId,
      '{model_name}': modelId,
      '{locale}': Platform.localeName,
      '{timezone}': now.timeZoneName,
      '{system_version}': '$os $osv',
      '{device_info}': os,
      '{battery_level}': 'unknown',
      '{nickname}': userNickname,
      '{assistant_name}': assistant.name,
    };
  }

  /// Assembles the full silent care request (Pipeline ②):
  /// system prompt (placeholders replaced) + memories + recent chats +
  /// instruction/world-book injections + conversation history + the care
  /// prompt with the current system time as the final user turn. Smart-time
  /// notes and the assistant's context limit are applied last.
  Future<List<Map<String, dynamic>>> buildCareApiMessages({
    required Assistant assistant,
    required String userNickname,
    required String modelId,
    required List<Map<String, dynamic>> history,
    required String carePrompt,
    required DateTime now,
    List<Conversation> recentChats = const <Conversation>[],
    bool reloadWorldBooks = false,
  }) async {
    final apiMessages = <Map<String, dynamic>>[
      for (final m in history) Map<String, dynamic>.of(m),
    ];

    // The care prompt is the final user turn so the model replies to it.
    apiMessages.add({
      'role': 'user',
      'content': ProactiveCareService.buildCareUserMessage(
        carePrompt: carePrompt,
        now: now,
      ),
    });

    if (assistant.systemPrompt.trim().isNotEmpty) {
      final vars = buildHeadlessPlaceholders(
        assistant: assistant,
        modelId: modelId,
        userNickname: userNickname,
        now: now,
      );
      apiMessages.insert(0, {
        'role': 'system',
        'content': PromptTransformer.replacePlaceholders(
          assistant.systemPrompt,
          vars,
        ),
      });
    }

    // Memory records.
    if (assistant.enableMemory) {
      try {
        final block = ProactiveCareService.buildMemoriesBlock(
          await _memoryStore.getForAssistant(assistant.id),
        );
        if (block.isNotEmpty) {
          _appendToSystemMessage(apiMessages, block);
        }
      } catch (e) {
        FlutterLogger.log('Memory injection failed: $e', tag: _logTag);
      }
    }

    // Recent chat references use the same block shape as normal chat, but the
    // caller supplies the already selected conversations because foreground
    // and killed-process paths have different storage access.
    if (assistant.enableRecentChatsReference && recentChats.isNotEmpty) {
      final block = ChatContextTransforms.buildRecentChatsBlock(recentChats);
      if (block.isNotEmpty) {
        _appendToSystemMessage(apiMessages, block);
      }
    }

    // Instruction injections.
    try {
      final actives = await _instructionInjectionStore.getActives(
        assistantId: assistant.id,
      );
      final prompts = actives
          .map((e) => e.prompt.trim())
          .where((p) => p.isNotEmpty)
          .toList(growable: false);
      if (prompts.isNotEmpty) {
        _appendToSystemMessage(apiMessages, prompts.join('\n\n'));
      }
    } catch (e) {
      FlutterLogger.log('Instruction injection failed: $e', tag: _logTag);
    }

    // World book entries. Load from the persistent store so this works in
    // both the main isolate and a headless alarm isolate.
    try {
      final selection = reloadWorldBooks
          ? await _worldBookStore.loadFreshForAssistant(
              assistantId: assistant.id,
            )
          : (
              books: await _worldBookStore.getAll(),
              activeBookIds: await _worldBookStore.getActiveIds(
                assistantId: assistant.id,
              ),
            );
      WorldBookPromptInjector.inject(
        messages: apiMessages,
        books: selection.books,
        activeBookIds: selection.activeBookIds,
      );
    } catch (e) {
      FlutterLogger.log('World book injection failed: $e', tag: _logTag);
    }

    if (assistant.enableTimeInjection) {
      ChatContextTransforms.injectTimeNote(apiMessages);
    }

    // Unlike the decision request, care generation follows the assistant's
    // ordinary context-message limit.
    ChatContextTransforms.applyMessageLimit(apiMessages, assistant);

    return apiMessages;
  }

  static void _appendToSystemMessage(
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

  /// Sends the silent care request and returns the aggregated reply text.
  Future<String> requestCareReply({
    required ProviderConfig config,
    required String modelId,
    required Assistant assistant,
    required List<Map<String, dynamic>> apiMessages,
    int? fallbackThinkingBudget,
  }) async {
    // Layer-① collector (ADR-0034): accumulate the silent no-tool stream.
    final text = await PlainTextCollector().collect(
      config: config,
      modelId: modelId,
      messages: apiMessages,
      thinkingBudget: assistant.thinkingBudget ?? fallbackThinkingBudget,
      // No temperature: silent background generation — a rejected sampling
      // parameter would fail the care reply invisibly (many models no longer
      // support it). The assistant's temperature still applies to the main
      // chat path.
      topP: assistant.topP,
      maxTokens: assistant.maxTokens,
      stream: false,
    );
    return text.trim();
  }

  static const Duration _decisionTimeout = Duration(seconds: 45);

  /// Silently asks the decision model for the next proactive care time
  /// (Pipeline ①) via tool calls. Returns null when the model keeps the
  /// current time, declines, fails, or returns an invalid/past time.
  ///
  /// [decisionTimeout] bounds each attempt's stream (tests inject a tiny
  /// value); defaults to [_decisionTimeout].
  Future<DateTime?> decideNextCareTime({
    required ProviderConfig config,
    required String modelId,
    required Assistant assistant,
    required String userNickname,
    required List<Map<String, dynamic>> history,
    required String decisionPrompt,
    int? fallbackThinkingBudget,
    ProactiveCareDecisionSender? sendMessageStream,
    Duration decisionTimeout = _decisionTimeout,
  }) async {
    if (history.isEmpty) return null;
    final send = sendMessageStream ?? ChatApiService.sendMessageStream;
    final now = DateTime.now();

    String personaPrompt = '';
    if (assistant.systemPrompt.trim().isNotEmpty) {
      final vars = buildHeadlessPlaceholders(
        assistant: assistant,
        modelId: modelId,
        userNickname: userNickname,
        now: now,
      );
      personaPrompt = PromptTransformer.replacePlaceholders(
        assistant.systemPrompt,
        vars,
      );
    }
    String memoriesBlock = '';
    if (assistant.enableMemory) {
      try {
        memoriesBlock = ProactiveCareService.buildMemoriesBlock(
          await _memoryStore.getForAssistant(assistant.id),
        );
      } catch (e) {
        FlutterLogger.log('Decision memories load failed: $e', tag: _logTag);
      }
    }

    final apiMessages = ProactiveCareService.buildDecisionApiMessages(
      decisionPrompt: decisionPrompt,
      currentNextCareTime: assistant.proactiveCareNextMessageAt,
      now: now,
      history: history,
      personaPrompt: personaPrompt,
      memoriesBlock: memoriesBlock,
    );
    if (assistant.enableTimeInjection) {
      ChatContextTransforms.injectTimeNote(apiMessages);
    }
    final tools = ProactiveCareDecisionTools.definitions();
    final baseRequestId =
        'proactive-care-decision-${assistant.id}-${DateTime.now().microsecondsSinceEpoch}';

    void logSettled(String attempt, DateTime? time) {
      FlutterLogger.log(
        'Decision settled ($attempt, model: $modelId): '
        '${time?.toIso8601String() ?? 'keep current time'}',
        tag: _logTag,
      );
    }

    final first = await _callDecisionOnce(
      send: send,
      config: config,
      modelId: modelId,
      messages: apiMessages,
      tools: tools,
      assistant: assistant,
      fallbackThinkingBudget: fallbackThinkingBudget,
      timeout: decisionTimeout,
      requestId: baseRequestId,
    );
    if (first.decided) {
      logSettled('attempt 1', first.time);
      return first.time;
    }

    // One Director-style retry with an explicit tool-only directive.
    final retryMessages = List<Map<String, dynamic>>.from(apiMessages)
      ..add({
        'role': 'user',
        'content': ProactiveCareService.builtinDecisionToolOnlyDirective,
      });
    final second = await _callDecisionOnce(
      send: send,
      config: config,
      modelId: modelId,
      messages: retryMessages,
      tools: tools,
      assistant: assistant,
      fallbackThinkingBudget: fallbackThinkingBudget,
      timeout: decisionTimeout,
      requestId: '$baseRequestId-retry',
    );
    if (second.decided) {
      logSettled('retry', second.time);
      return second.time;
    }

    FlutterLogger.log(
      'Decision finished without a tool call (model: $modelId); '
      'keeping current time',
      tag: _logTag,
    );
    return null;
  }

  /// One decision attempt. `decided == true` means a recognized tool call
  /// settled the outcome (`time` may still be null = keep current time);
  /// `decided == false` means the attempt produced no decision (free text,
  /// error, timeout) and the caller may retry.
  Future<({bool decided, DateTime? time})> _callDecisionOnce({
    required ProactiveCareDecisionSender send,
    required ProviderConfig config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required Assistant assistant,
    required int? fallbackThinkingBudget,
    required Duration timeout,
    required String requestId,
  }) async {
    var decided = false;
    DateTime? decisionTime;
    final completer = Completer<DateTime?>();
    StreamSubscription<ChatStreamChunk>? sub;

    void finish(DateTime? time) {
      if (decided) return;
      decided = true;
      decisionTime = time;
      if (!completer.isCompleted) completer.complete(time);
      // The first recognized tool call IS the decision. Cancel the stream so
      // the provider cannot start follow-up tool rounds (Director pattern).
      unawaited(sub?.cancel());
      ChatApiService.cancelRequest(requestId);
    }

    void maybeDecide(String name, Map<String, dynamic> args) {
      if (decided) return;
      if (ProactiveCareDecisionTools.isKeepTime(name)) {
        finish(null);
      } else if (ProactiveCareDecisionTools.isUpdateTime(name)) {
        // Validate against a fresh clock: the request-level `now` (time
        // footer) can be stale by the time a tool call arrives.
        final time = ProactiveCareDecisionTools.parseUpdateTimeArgs(
          args,
          now: DateTime.now(),
        );
        if (time == null) {
          FlutterLogger.log(
            'Decision ${ProactiveCareDecisionTools.updateTime} args '
            'invalid/past: $args',
            tag: _logTag,
          );
        }
        finish(time); // invalid/past → null → keep current time (final)
      }
      // Unknown tool names: stay undecided; neutral result keeps stream going.
    }

    Future<String> onToolCall(
      String name,
      Map<String, dynamic> args, {
      String? toolCallId,
    }) async {
      maybeDecide(name, args);
      // Keep the result neutral — never 'ignored' (models retry-loop on it).
      return jsonEncode({'ok': true});
    }

    try {
      final stream = send(
        config: config,
        modelId: modelId,
        messages: messages,
        tools: tools,
        onToolCall: onToolCall,
        thinkingBudget: assistant.thinkingBudget ?? fallbackThinkingBudget,
        // No temperature (same rationale as requestCareReply: silent
        // background call; the decision extraction itself is sampling-
        // agnostic).
        topP: assistant.topP,
        maxTokens: assistant.maxTokens,
        stream: false,
        requestId: requestId,
        // This flow performs its own single retry ('-retry' suffix id); the
        // user-configurable backoff would double attempts on free-tier limits.
        retryOverride: const AutoRetryOptions.defaults(),
      );

      sub = stream.listen(
        (chunk) {
          if (decided) return;
          final calls = chunk.toolCalls;
          if (calls == null || calls.isEmpty) return;
          for (final c in calls) {
            maybeDecide(c.name, Map<String, dynamic>.from(c.arguments));
            if (decided) break;
          }
        },
        onError: (Object e) {
          if (!completer.isCompleted) completer.completeError(e);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(null);
        },
        cancelOnError: true,
      );

      await completer.future.timeout(
        timeout,
        onTimeout: () {
          unawaited(sub?.cancel());
          ChatApiService.cancelRequest(requestId);
          throw TimeoutException('proactive care decision timeout');
        },
      );
    } catch (e) {
      FlutterLogger.log('Decision call failed: $e', tag: _logTag);
    }
    return (decided: decided, time: decisionTime);
  }
}

/// Direct SQLite access used ONLY by the proactive care background isolate
/// when the app process is dead, so no ChatService instance has the database
/// open. Never call this from the main isolate: SQLite WAL mode does not
/// support concurrent multi-isolate writes to the same database file.
class ProactiveCareHeadlessChatStore {
  const ProactiveCareHeadlessChatStore._();

  /// Overridable for tests, where path_provider is unavailable.
  @visibleForTesting
  static Future<String> Function() dataDirPathProvider = () async =>
      (await AppDirectories.getAppDataDirectory()).path;

  static sqlite.Database? _db;

  /// Opens the shared `kelivo.sqlite` (WAL + busy_timeout, mirroring the
  /// Drift executor). Exposed so helper isolates (proactive-care alarm) can
  /// build raw-sqlite stores over business tables without Drift.
  static Future<sqlite.Database> openSharedSqlite() async {
    final dirPath = await dataDirPathProvider();
    final dbPath = '$dirPath/kelivo.sqlite';
    final db = sqlite.sqlite3.open(dbPath);
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute('PRAGMA busy_timeout = 5000;');
    return db;
  }

  static Future<sqlite.Database> _ensureDb() async {
    if (_db != null) return _db!;
    _db = await openSharedSqlite();
    return _db!;
  }

  /// Converts a raw SQLite value to [DateTime].
  /// Drift 2.x stores DateTime as unix timestamp (seconds, INTEGER) by
  /// default (`store_date_time_values_as_text` is false without build.yaml).
  static DateTime _dateTimeFromSql(Object? value) {
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value * 1000);
    }
    // Fallback for ISO-8601 text (should not happen with default drift config)
    return DateTime.parse(value as String);
  }

  static DateTime? _dateTimeFromSqlNullable(Object? value) {
    if (value == null) return null;
    return _dateTimeFromSql(value);
  }

  static String? _readOptionalString(sqlite.Row row, String column) {
    try {
      return row[column]?.toString();
    } catch (error) {
      FlutterLogger.log(
        'Optional assistant column $column is unavailable: $error',
        tag: _logTag,
      );
      return null;
    }
  }

  /// Converts [DateTime] to unix timestamp seconds for drift compatibility.
  static int _dateTimeToSql(DateTime dt) => dt.millisecondsSinceEpoch ~/ 1000;

  /// Loads a single assistant by id from the `assistant_rows` table.
  static Future<Assistant?> loadAssistantFor(String assistantId) async {
    final db = await _ensureDb();
    final rows = db.select('SELECT * FROM assistant_rows WHERE id = ?', [
      assistantId,
    ]);
    if (rows.isEmpty) return null;
    return _assistantFromRow(rows.first);
  }

  /// Updates the proactive care next-message time for [assistantId].
  static Future<void> updateNextCareTime(
    String assistantId,
    DateTime nextCareTime,
  ) async {
    final db = await _ensureDb();
    db.execute(
      'UPDATE assistant_rows SET proactive_care_next_message_at = ? WHERE id = ?',
      [_dateTimeToSql(nextCareTime), assistantId],
    );
  }

  /// Maps a raw sqlite3 row to an [Assistant] via its JSON constructor,
  /// mirroring `ChatDatabaseRepository._assistantFromRow`.
  static Assistant _assistantFromRow(sqlite.Row row) {
    return Assistant.fromJson({
      'id': row['id'] as String,
      'name': row['name'] as String,
      'avatar': row['avatar'] as String?,
      'useAssistantAvatar': (row['use_assistant_avatar'] as int) != 0,
      'useAssistantName': (row['use_assistant_name'] as int) != 0,
      'background': row['background'] as String?,
      'chatModelProvider': row['chat_model_provider'] as String?,
      'chatModelId': row['chat_model_id'] as String?,
      'temperature': row['temperature'] as double?,
      'topP': row['top_p'] as double?,
      'contextMessageSize': row['context_message_size'] as int,
      'limitContextMessages': (row['limit_context_messages'] as int) != 0,
      'streamOutput': (row['stream_output'] as int) != 0,
      'thinkingBudget': row['thinking_budget'] as int?,
      'maxTokens': row['max_tokens'] as int?,
      'systemPrompt': row['system_prompt'] as String,
      'messageTemplate': row['message_template'] as String,
      'searchEnabled': (row['search_enabled'] as int) != 0,
      'mcpServerIds': (jsonDecode(row['mcp_server_ids_json'] as String) as List)
          .cast<String>(),
      'localToolIds': (jsonDecode(row['local_tool_ids_json'] as String) as List)
          .cast<String>(),
      'skillIds': (jsonDecode(row['skill_ids_json'] as String) as List)
          .cast<String>(),
      'workspaceEnabled': (row['workspace_enabled'] as int? ?? 0) != 0,
      'workspaceId': row['workspace_id'] as String?,
      'workspaceDefaultDirectories': jsonDecode(
        _readOptionalString(row, 'workspace_default_directories_json') ?? '{}',
      ),
      'autoLoadAgentsMd':
          (_readOptionalString(row, 'auto_load_agents_md') ?? '1') != '0',
      'customHeaders': jsonDecode(row['custom_headers_json'] as String),
      'customBody': jsonDecode(row['custom_body_json'] as String),
      'enableMemory': (row['enable_memory'] as int) != 0,
      'memoryMode': row['memory_mode'] as String,
      'enableRecentChatsReference':
          (row['enable_recent_chats_reference'] as int) != 0,
      'recentChatsSummaryMessageCount':
          row['recent_chats_summary_message_count'] as int,
      'memoryRecordPrompt': row['memory_record_prompt'] as String,
      'docxMode': row['docx_mode'] as String,
      'pdfMode': row['pdf_mode'] as String,
      'otherOfficeMode': row['other_office_mode'] as String,
      'ocrMode': row['ocr_mode'] as String? ?? 'auto',
      'presetMessages': jsonDecode(row['preset_messages_json'] as String),
      'regexRules': jsonDecode(row['regex_rules_json'] as String),
      'enableProactiveCare': (row['enable_proactive_care'] as int) != 0,
      'enableTimeInjection': (row['enable_time_injection'] as int) != 0,
      'discoverable': (row['discoverable'] as int? ?? 0) != 0,
      'handoffId': row['handoff_id'] as String?,
      'handoffDescription': row['handoff_description'] as String?,
      'proactiveCareNextMessageAt': _dateTimeFromSqlNullable(
        row['proactive_care_next_message_at'],
      )?.toIso8601String(),
      'proactiveCarePrompt': row['proactive_care_prompt'] as String,
      'proactiveCareDecisionPrompt':
          row['proactive_care_decision_prompt'] as String,
      'createdAt': _dateTimeFromSql(row['created_at']).toIso8601String(),
      'updatedAt': _dateTimeFromSql(row['updated_at']).toIso8601String(),
    });
  }

  /// Returns the most recently active conversation of [assistantId] and its
  /// messages, or a null conversation when the assistant has none.
  static Future<({Conversation? conversation, List<ChatMessage> messages})>
  loadRecentConversationFor(String assistantId) async {
    final db = await _ensureDb();

    // Find the most recent non-group conversation for this assistant.
    final convRows = db.select(
      'SELECT * FROM conversation_rows '
      'WHERE assistant_id = ? AND conversation_kind != ? '
      'ORDER BY updated_at DESC LIMIT 1',
      [assistantId, Conversation.kindGroup],
    );
    if (convRows.isEmpty) {
      return (conversation: null, messages: const <ChatMessage>[]);
    }

    final row = convRows.first;
    final conversation = Conversation(
      id: row['id'] as String,
      title: row['title'] as String,
      createdAt: _dateTimeFromSql(row['created_at']),
      updatedAt: _dateTimeFromSql(row['updated_at']),
      isPinned: (row['is_pinned'] as int) != 0,
      assistantId: row['assistant_id'] as String?,
      truncateIndex: row['truncate_index'] as int? ?? -1,
      versionSelections: _parseVersionSelections(
        row['version_selections_json'] as String?,
      ),
      summary: row['summary'] as String?,
      lastSummarizedMessageCount:
          row['last_summarized_message_count'] as int? ?? 0,
      parentConversationId: row['parent_conversation_id'] as String?,
      conversationKind:
          row['conversation_kind'] as String? ?? Conversation.kindNormal,
    );

    // Load messages for this conversation
    final msgRows = db.select(
      'SELECT * FROM message_rows WHERE conversation_id = ? ORDER BY message_order ASC',
      [conversation.id],
    );
    final messages = <ChatMessage>[];
    for (final mRow in msgRows) {
      messages.add(
        ChatMessage(
          id: mRow['id'] as String,
          role: mRow['role'] as String,
          content: mRow['content'] as String,
          timestamp: _dateTimeFromSql(mRow['timestamp']),
          modelId: mRow['model_id'] as String?,
          providerId: mRow['provider_id'] as String?,
          totalTokens: mRow['total_tokens'] as int?,
          conversationId: mRow['conversation_id'] as String,
          isStreaming: (mRow['is_streaming'] as int? ?? 0) != 0,
          groupId: mRow['group_id'] as String?,
          subgroupId: mRow['subgroup_id'] as String?,
          version: mRow['version'] as int? ?? 0,
          isPreset: (mRow['is_preset'] as int? ?? 0) != 0,
        ),
      );
    }

    return (conversation: conversation, messages: messages);
  }

  /// Loads the same recent-chat references used by the foreground builder.
  static Future<List<Conversation>> loadRecentChatReferencesFor(
    String assistantId, {
    required String? currentConversationId,
  }) async {
    final db = await _ensureDb();
    final exclusion = currentConversationId == null ? '' : 'AND id != ? ';
    final parameters = <Object?>[
      assistantId,
      Conversation.kindGroup,
      if (currentConversationId != null) currentConversationId,
    ];
    final rows = db.select(
      'SELECT id, title, created_at, updated_at, assistant_id, summary, '
      'conversation_kind FROM conversation_rows '
      'WHERE assistant_id = ? AND conversation_kind != ? '
      '${exclusion}AND TRIM(title) != \'\' '
      'ORDER BY updated_at DESC LIMIT 10',
      parameters,
    );
    return rows
        .map(
          (row) => Conversation(
            id: row['id'] as String,
            title: row['title'] as String,
            createdAt: _dateTimeFromSql(row['created_at']),
            updatedAt: _dateTimeFromSql(row['updated_at']),
            assistantId: row['assistant_id'] as String?,
            summary: row['summary'] as String?,
            conversationKind:
                row['conversation_kind'] as String? ?? Conversation.kindNormal,
          ),
        )
        .toList(growable: false);
  }

  /// Appends an assistant reply to [conversation], creating a new
  /// conversation titled [fallbackTitle] when null.
  static Future<({Conversation conversation, ChatMessage message})>
  appendAssistantReply({
    required String assistantId,
    required Conversation? conversation,
    required String content,
    required String fallbackTitle,
    String? modelId,
    String? providerId,
  }) async {
    final db = await _ensureDb();

    final convo =
        conversation ??
        Conversation(title: fallbackTitle, assistantId: assistantId);

    final message = ChatMessage(
      role: 'assistant',
      content: content,
      conversationId: convo.id,
      modelId: modelId,
      providerId: providerId,
    );

    // Insert message (id is always a fresh UUID, plain INSERT is safe)
    final msgCount =
        (db.select(
              'SELECT COUNT(*) as cnt FROM message_rows WHERE conversation_id = ?',
              [convo.id],
            ).first['cnt']
            as int);

    db.execute(
      '''INSERT INTO message_rows
         (id, conversation_id, role, content, timestamp, model_id, provider_id,
          total_tokens, is_streaming, group_id, subgroup_id, version, message_order)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        message.id,
        convo.id,
        message.role,
        message.content,
        _dateTimeToSql(message.timestamp),
        message.modelId,
        message.providerId,
        message.totalTokens,
        0,
        message.groupId,
        message.subgroupId,
        message.version,
        msgCount,
      ],
    );

    // Update conversation — use UPDATE for existing conversations to avoid
    // INSERT OR REPLACE triggering ON DELETE CASCADE on message_rows.
    convo.updatedAt = DateTime.now();
    if (conversation != null) {
      // Existing conversation: only touch updated_at.
      db.execute('UPDATE conversation_rows SET updated_at = ? WHERE id = ?', [
        _dateTimeToSql(convo.updatedAt),
        convo.id,
      ]);
    } else {
      // Brand-new conversation: safe to INSERT.
      db.execute(
        '''INSERT INTO conversation_rows
           (id, title, created_at, updated_at, is_pinned, assistant_id,
            truncate_index, version_selections_json)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          convo.id,
          convo.title,
          _dateTimeToSql(convo.createdAt),
          _dateTimeToSql(convo.updatedAt),
          convo.isPinned ? 1 : 0,
          convo.assistantId,
          convo.truncateIndex,
          jsonEncode(convo.versionSelections),
        ],
      );
    }

    return (conversation: convo, message: message);
  }

  /// Flushes and closes the database so all writes hit disk before the
  /// background isolate is torn down.
  static Future<void> close() async {
    try {
      _db?.close();
      _db = null;
    } catch (e) {
      FlutterLogger.log('DB close failed: $e', tag: _logTag);
    }
  }

  static Map<String, int> _parseVersionSelections(String? json) {
    if (json == null || json.isEmpty) return <String, int>{};
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, v as int));
    } catch (_) {
      return <String, int>{};
    }
  }
}
