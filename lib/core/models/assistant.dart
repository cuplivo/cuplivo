import 'dart:convert';
import 'assistant_regex.dart';
import 'harness_tailcat_endpoint.dart';
import 'health_data_type.dart';
import 'memory_entry.dart';
import 'preset_message.dart';
import 'reasoning_request.dart';

enum MemorySmartAddMode { batched, perItem }

enum DefaultWorkspaceSetup { automatic, suggest, completed }

enum MemoryWriteScope {
  alwaysGlobal,
  alwaysAssistant,
  toolDefaultGlobal,
  toolDefaultAssistant,
}

/// How far a delegated task may spend the user's permission.
///
/// The question only comes up where a tool call would ask the user to approve
/// something inside a child conversation — a card the user may not be looking at.
/// `allow` is capped by the conversation that delegated: it can only reach what
/// that conversation already has, and falls back to asking when it cannot.
enum SubagentEscalation { ask, deny, allow }

/// What an assistant is.
///
/// A [local] assistant is a chat configuration this app runs. A
/// [deepSeekHarness] assistant is a pointer to a remote DeepSeek Harness
/// instance: the app embeds that instance's own WebUI instead of using the
/// assistant as a chat model, so the chat settings do not apply to it.
enum AssistantKind { local, deepSeekHarness }

/// How a [AssistantKind.deepSeekHarness] assistant reaches its instance.
///
/// [publicLink] is the launch link `dsh web` prints: an http(s) URL carrying
/// the instance's launch token. [tailcat] is the ds-hu remote-access plugin:
/// the instance publishes its Web listener on a tailnet address, and the app
/// dials it through a tailcat tunnel and serves it to the embedded WebView from
/// a loopback port, so no port has to be exposed to the internet.
enum HarnessConnectionMode { publicLink, tailcat }

/// The shallowest and deepest chain a delegation from one assistant may build.
///
/// 1 is "a subagent may not delegate again", which is what every assistant had
/// before this setting existed; 3 is two further levels. The ceiling is small on
/// purpose: each level is a whole extra context billed to the same request.
const int kSubagentDepthMin = 1;
const int kSubagentDepthMax = 3;

class Assistant {
  static const int defaultRecentChatsSummaryMessageCount = 5;
  static const int defaultMemoryOrganizeEveryNTurns = 1;
  static const int minMemoryOrganizeEveryNTurns = 1;
  static const int maxMemoryOrganizeEveryNTurns = 20;
  static const double defaultTemperature = 1.0;
  static const double defaultGradientBackgroundPhase = 7.0;
  static const int minContextMessageSize = 1;
  static const int maxContextMessageSize = 4096;
  static const List<int> recentChatsSummaryMessageCountOptions = <int>[
    1,
    3,
    5,
    10,
    20,
    50,
  ];

  final String id;
  final String name;
  final AssistantKind kind;

  /// The DeepSeek Harness WebUI launch link, token included, for a
  /// [AssistantKind.deepSeekHarness] assistant connected through
  /// [HarnessConnectionMode.publicLink]. `null` until the user connects one;
  /// ignored for a local assistant.
  final String? harnessUrl;

  /// How a [AssistantKind.deepSeekHarness] assistant reaches its instance.
  /// Ignored for a local assistant, whose conversations never leave the app.
  final HarnessConnectionMode harnessConnectionMode;

  /// The tailcat address of a [HarnessConnectionMode.tailcat] assistant, as
  /// the ds-hu plugin's pairing page shows it. `null` until the user connects
  /// one; ignored in the other modes.
  ///
  /// This is a capability secret like [harnessUrl]: whoever holds the address
  /// can open the instance's door, so it is stored but never rendered back.
  final String? harnessTailcatAddress;

  /// The peer port the plugin's tunnel serves the WebUI on.
  ///
  /// The plugin defaults to [kHarnessTailcatDefaultPort]; a pairing command
  /// that maps another port overrides it.
  final int harnessTailcatPort;

  bool get isDeepSeekHarness => kind == AssistantKind.deepSeekHarness;

  /// Whether this harness has the credential its [harnessConnectionMode]
  /// needs. A harness assistant may exist before it is connected: it is a card
  /// in the assistants list whose settings page is the only thing to open.
  bool get hasHarnessConnection => switch (harnessConnectionMode) {
    HarnessConnectionMode.publicLink => harnessUrl?.trim().isNotEmpty ?? false,
    HarnessConnectionMode.tailcat =>
      harnessTailcatAddress?.trim().isNotEmpty ?? false,
  };

  final String? avatar; // path/url/base64, null for initial-letter avatar
  final bool
  useAssistantAvatar; // replace model icon in chat with assistant avatar
  final bool useAssistantName; // replace model name in chat with assistant name
  final String? chatModelProvider; // null -> use global default
  final String? chatModelId; // null -> use global default
  final double? temperature; // null to disable; else 0.0 - 2.0
  final double? topP; // null to disable; else 0.0 - 1.0
  final int contextMessageSize; // number of previous messages to include
  final bool limitContextMessages; // whether to enforce contextMessageSize
  final bool streamOutput; // streaming responses
  final ReasoningRequest? reasoning; // null = no assistant default
  final int? maxTokens; // null = unlimited
  final String systemPrompt;
  final bool allowConversationSystemPrompt;
  final bool allowConversationPromptInjection;
  final String messageTemplate; // e.g. "{{ message }}"
  final bool searchEnabled; // per-assistant external web search switch

  /// Per-assistant opt-out of chat suggestions. The global switch in Default
  /// Models stays the master; this only decides whether this assistant is
  /// covered when it is on.
  final bool suggestionsEnabled;
  final List<String> mcpServerIds; // bound MCP server IDs
  final bool allowConversationMcp;
  final List<String> localToolIds; // enabled local tool IDs

  /// Which model draws this assistant's pictures. `null` falls through to
  /// 设置 → 默认模型 → 绘图模型. The text model writes the prompt; it never
  /// chooses the brush, and a conversation has no say in it either.
  final String? imageModelProvider;
  final String? imageModelId;

  /// Which model a delegated task runs on. `null` follows the conversation that
  /// delegated, which is what the user is already paying for; an assistant that
  /// delegates a lot may point it at something cheaper or stronger.
  final String? subagentModelProvider;
  final String? subagentModelId;

  /// How far a delegated task may spend the user's permission.
  final SubagentEscalation subagentEscalation;

  /// Which of the user's other assistants this one may hand a task to, by id.
  ///
  /// Empty is the default and means none: a delegation then offers the model no
  /// `target` parameter at all, so the tool schema a conversation sends is
  /// byte-for-byte the one it sent before this field existed.
  final List<String> subagentTargetIds;

  /// How many levels of subagent this assistant's delegations may build,
  /// counting the first child as level 1. 1 is "the subagent does not get the
  /// tool", which is what every assistant did before the setting existed.
  ///
  /// It is a ceiling, not a promise: a delegation into an assistant whose own
  /// depth is shallower stops at that assistant's number, because that
  /// assistant's conversation is the one spending the tokens.
  final int subagentDepth;

  /// What this assistant is for, in one or two sentences.
  ///
  /// Read by the two places that ask a model to pick an assistant: the
  /// delegation target list and the group chat director's roster. Empty means
  /// the roster shows the name alone, which is what it did before the field.
  final String description;

  /// A description is a sentence for a model to read, not an essay; the bound
  /// is what the editor enforces and what the roster can afford.
  static const int maxDescriptionLength = 300;

  /// Default workspace for new conversations started with this assistant.
  final String? defaultWorkspaceId;

  /// New assistants remember the first binding; existing assistants only suggest it.
  final DefaultWorkspaceSetup defaultWorkspaceSetup;

  /// Runtime-only identity for default-workspace edits, including selecting the
  /// same value. Unrelated edits preserve it; it is not serialized.
  final Object? defaultWorkspaceChangeToken;

  /// Enabled skill IDs. `null` means every installed skill is available.
  final List<String>? skillIds;

  /// HealthKit metric IDs this collaborator may read. Kept when the health
  /// master toggle is off so turning it back on restores the selection.
  final List<String> healthDataTypeIds;
  final String? background; // chat background (color/image ref)
  final bool useGradientBackground;
  final bool gradientBackgroundAnimated;
  final double gradientBackgroundPhase;
  final double gradientBackgroundOffsetX;
  final double gradientBackgroundOffsetY;
  // Custom request overrides (per assistant)
  final List<Map<String, String>>
  customHeaders; // [{name:'X-Header', value:'v'}]
  final List<Map<String, String>> customBody; // [{key:'foo', value:'{"a":1}'}]
  // Memory features (§4.1)
  final bool enableMemory;
  final Set<MemoryType> memoryFullInjectionTypes;
  final bool autoOrganizeMemory;
  final int memoryOrganizeEveryNTurns;
  final MemorySmartAddMode memorySmartAddMode;
  final MemoryWriteScope memoryWriteScope;
  final bool allowPastConversationRecall;
  final bool generateConversationSummary;
  final int
  recentChatsSummaryMessageCount; // refresh summary after N new messages
  final bool appendCurrentTimeToUserMessage;
  final bool useIso8601TimeFormat;
  // Preset conversation messages (ordered)
  final List<PresetMessage> presetMessages;
  // Regex replacement rules
  final List<AssistantRegex> regexRules;
  // Proactive care ("Ta的来信")
  final bool enableProactiveCare;
  final String proactiveCarePrompt;
  final String proactiveCareDecisionPrompt;
  final int? proactiveCareDecisionHistoryMessageLimit;

  /// Clamps the nullable decision-history window into
  /// [minContextMessageSize, maxContextMessageSize]. Called from every write
  /// path (copyWith/fromJson) so a save converges; kept as a static so the
  /// constructor can stay const.
  static int? _normalizeProactiveCareHistoryLimit(int? v) =>
      v?.clamp(minContextMessageSize, maxContextMessageSize).toInt();

  const Assistant({
    required this.id,
    required this.name,
    this.kind = AssistantKind.local,
    this.harnessUrl,
    this.harnessConnectionMode = HarnessConnectionMode.publicLink,
    this.harnessTailcatAddress,
    this.harnessTailcatPort = kHarnessTailcatDefaultPort,
    this.avatar,
    this.useAssistantAvatar = false,
    this.useAssistantName = false,
    this.chatModelProvider,
    this.chatModelId,
    this.temperature,
    this.topP,
    this.contextMessageSize = 64,
    this.limitContextMessages = false,
    this.streamOutput = true,
    this.reasoning,
    this.maxTokens,
    this.systemPrompt = '',
    this.allowConversationSystemPrompt = false,
    this.allowConversationPromptInjection = false,
    this.messageTemplate = '{{ message }}',
    this.searchEnabled = false,
    this.suggestionsEnabled = true,
    this.mcpServerIds = const <String>[],
    this.allowConversationMcp = false,
    this.localToolIds = const <String>[],
    this.imageModelProvider,
    this.imageModelId,
    this.subagentModelProvider,
    this.subagentModelId,
    this.subagentEscalation = SubagentEscalation.ask,
    this.subagentTargetIds = const <String>[],
    this.subagentDepth = kSubagentDepthMin,
    this.description = '',
    this.defaultWorkspaceId,
    this.defaultWorkspaceSetup = DefaultWorkspaceSetup.automatic,
    this.defaultWorkspaceChangeToken,
    this.skillIds,
    this.healthDataTypeIds = HealthDataTypeIds.defaultSelected,
    this.background,
    this.useGradientBackground = false,
    this.gradientBackgroundAnimated = true,
    this.gradientBackgroundPhase = defaultGradientBackgroundPhase,
    this.gradientBackgroundOffsetX = 0,
    this.gradientBackgroundOffsetY = 0,
    this.customHeaders = const <Map<String, String>>[],
    this.customBody = const <Map<String, String>>[],
    this.enableMemory = false,
    this.memoryFullInjectionTypes = const {},
    this.autoOrganizeMemory = false,
    this.memoryOrganizeEveryNTurns = defaultMemoryOrganizeEveryNTurns,
    this.memorySmartAddMode = MemorySmartAddMode.batched,
    this.memoryWriteScope = MemoryWriteScope.alwaysGlobal,
    this.allowPastConversationRecall = false,
    this.generateConversationSummary = false,
    this.recentChatsSummaryMessageCount = defaultRecentChatsSummaryMessageCount,
    this.appendCurrentTimeToUserMessage = false,
    this.useIso8601TimeFormat = false,
    this.presetMessages = const <PresetMessage>[],
    this.regexRules = const <AssistantRegex>[],
    this.enableProactiveCare = false,
    this.proactiveCarePrompt = '',
    this.proactiveCareDecisionPrompt = '',
    this.proactiveCareDecisionHistoryMessageLimit,
  });

  /// A remote DeepSeek Harness, before (or after) it is connected.
  ///
  /// It owns a name, a connection mode and that mode's credential and nothing
  /// else: no model, no prompt, no tools — the remote instance brings its own.
  factory Assistant.harness({
    required String id,
    required String name,
    HarnessConnectionMode harnessConnectionMode =
        HarnessConnectionMode.publicLink,
    String? harnessUrl,
    String? harnessTailcatAddress,
    int harnessTailcatPort = kHarnessTailcatDefaultPort,
  }) => Assistant(
    id: id,
    name: name,
    kind: AssistantKind.deepSeekHarness,
    harnessUrl: harnessUrl,
    harnessConnectionMode: harnessConnectionMode,
    harnessTailcatAddress: harnessTailcatAddress,
    harnessTailcatPort: harnessTailcatPort,
    temperature: null,
    topP: null,
    limitContextMessages: false,
  );

  Assistant copyWith({
    String? id,
    String? name,
    AssistantKind? kind,
    String? harnessUrl,
    bool clearHarnessUrl = false,
    HarnessConnectionMode? harnessConnectionMode,
    String? harnessTailcatAddress,
    bool clearHarnessTailcatAddress = false,
    int? harnessTailcatPort,
    String? avatar,
    bool? useAssistantAvatar,
    bool? useAssistantName,
    String? chatModelProvider,
    String? chatModelId,
    double? temperature,
    double? topP,
    int? contextMessageSize,
    bool? limitContextMessages,
    bool? streamOutput,
    ReasoningRequest? reasoning,
    int? maxTokens,
    String? systemPrompt,
    bool? allowConversationSystemPrompt,
    bool? allowConversationPromptInjection,
    String? messageTemplate,
    bool? searchEnabled,
    bool? suggestionsEnabled,
    List<String>? mcpServerIds,
    bool? allowConversationMcp,
    List<String>? localToolIds,
    String? imageModelProvider,
    bool clearImageModelProvider = false,
    String? imageModelId,
    bool clearImageModelId = false,
    String? subagentModelProvider,
    bool clearSubagentModelProvider = false,
    String? subagentModelId,
    bool clearSubagentModelId = false,
    SubagentEscalation? subagentEscalation,
    List<String>? subagentTargetIds,
    int? subagentDepth,
    String? description,
    String? defaultWorkspaceId,
    DefaultWorkspaceSetup? defaultWorkspaceSetup,
    List<String>? skillIds,
    List<String>? healthDataTypeIds,
    String? background,
    bool? useGradientBackground,
    bool? gradientBackgroundAnimated,
    double? gradientBackgroundPhase,
    double? gradientBackgroundOffsetX,
    double? gradientBackgroundOffsetY,
    List<Map<String, String>>? customHeaders,
    List<Map<String, String>>? customBody,
    bool? enableMemory,
    Set<MemoryType>? memoryFullInjectionTypes,
    bool? autoOrganizeMemory,
    int? memoryOrganizeEveryNTurns,
    MemorySmartAddMode? memorySmartAddMode,
    MemoryWriteScope? memoryWriteScope,
    bool? allowPastConversationRecall,
    bool? generateConversationSummary,
    int? recentChatsSummaryMessageCount,
    bool? appendCurrentTimeToUserMessage,
    bool? useIso8601TimeFormat,
    List<PresetMessage>? presetMessages,
    List<AssistantRegex>? regexRules,
    bool? enableProactiveCare,
    String? proactiveCarePrompt,
    String? proactiveCareDecisionPrompt,
    int? proactiveCareDecisionHistoryMessageLimit,
    bool clearProactiveCareDecisionHistoryMessageLimit = false,
    bool clearChatModel = false,
    bool clearDefaultWorkspaceId = false,
    bool clearSkillIds = false,
    bool clearAvatar = false,
    bool clearTemperature = false,
    bool clearTopP = false,
    bool clearReasoning = false,
    bool clearMaxTokens = false,
    bool clearBackground = false,
  }) {
    return Assistant(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      harnessUrl: clearHarnessUrl ? null : (harnessUrl ?? this.harnessUrl),
      harnessConnectionMode:
          harnessConnectionMode ?? this.harnessConnectionMode,
      harnessTailcatAddress: clearHarnessTailcatAddress
          ? null
          : (harnessTailcatAddress ?? this.harnessTailcatAddress),
      harnessTailcatPort: harnessTailcatPort ?? this.harnessTailcatPort,
      avatar: clearAvatar ? null : (avatar ?? this.avatar),
      useAssistantAvatar: useAssistantAvatar ?? this.useAssistantAvatar,
      useAssistantName: useAssistantName ?? this.useAssistantName,
      chatModelProvider: clearChatModel
          ? null
          : (chatModelProvider ?? this.chatModelProvider),
      chatModelId: clearChatModel ? null : (chatModelId ?? this.chatModelId),
      temperature: clearTemperature ? null : (temperature ?? this.temperature),
      topP: clearTopP ? null : (topP ?? this.topP),
      contextMessageSize: contextMessageSize ?? this.contextMessageSize,
      limitContextMessages: limitContextMessages ?? this.limitContextMessages,
      streamOutput: streamOutput ?? this.streamOutput,
      reasoning: clearReasoning ? null : (reasoning ?? this.reasoning),
      maxTokens: clearMaxTokens ? null : (maxTokens ?? this.maxTokens),
      systemPrompt: systemPrompt ?? this.systemPrompt,
      allowConversationSystemPrompt:
          allowConversationSystemPrompt ?? this.allowConversationSystemPrompt,
      allowConversationPromptInjection:
          allowConversationPromptInjection ??
          this.allowConversationPromptInjection,
      messageTemplate: messageTemplate ?? this.messageTemplate,
      searchEnabled: searchEnabled ?? this.searchEnabled,
      suggestionsEnabled: suggestionsEnabled ?? this.suggestionsEnabled,
      mcpServerIds: mcpServerIds ?? this.mcpServerIds,
      allowConversationMcp: allowConversationMcp ?? this.allowConversationMcp,
      localToolIds: localToolIds ?? this.localToolIds,
      imageModelProvider: clearImageModelProvider
          ? null
          : (imageModelProvider ?? this.imageModelProvider),
      imageModelId: clearImageModelId
          ? null
          : (imageModelId ?? this.imageModelId),
      subagentModelProvider: clearSubagentModelProvider
          ? null
          : (subagentModelProvider ?? this.subagentModelProvider),
      subagentModelId: clearSubagentModelId
          ? null
          : (subagentModelId ?? this.subagentModelId),
      subagentEscalation: subagentEscalation ?? this.subagentEscalation,
      subagentTargetIds: subagentTargetIds ?? this.subagentTargetIds,
      subagentDepth: (subagentDepth ?? this.subagentDepth).clamp(
        kSubagentDepthMin,
        kSubagentDepthMax,
      ),
      description: description ?? this.description,
      defaultWorkspaceId: clearDefaultWorkspaceId
          ? null
          : (defaultWorkspaceId ?? this.defaultWorkspaceId),
      defaultWorkspaceSetup:
          defaultWorkspaceSetup ??
          (clearDefaultWorkspaceId || defaultWorkspaceId != null
              ? DefaultWorkspaceSetup.completed
              : this.defaultWorkspaceSetup),
      defaultWorkspaceChangeToken:
          clearDefaultWorkspaceId ||
              defaultWorkspaceId != null ||
              defaultWorkspaceSetup != null
          ? Object()
          : defaultWorkspaceChangeToken,
      skillIds: clearSkillIds ? null : (skillIds ?? this.skillIds),
      healthDataTypeIds: healthDataTypeIds ?? this.healthDataTypeIds,
      background: clearBackground ? null : (background ?? this.background),
      useGradientBackground:
          useGradientBackground ?? this.useGradientBackground,
      gradientBackgroundAnimated:
          gradientBackgroundAnimated ?? this.gradientBackgroundAnimated,
      gradientBackgroundPhase:
          gradientBackgroundPhase ?? this.gradientBackgroundPhase,
      gradientBackgroundOffsetX:
          gradientBackgroundOffsetX ?? this.gradientBackgroundOffsetX,
      gradientBackgroundOffsetY:
          gradientBackgroundOffsetY ?? this.gradientBackgroundOffsetY,
      customHeaders: customHeaders ?? this.customHeaders,
      customBody: customBody ?? this.customBody,
      enableMemory: enableMemory ?? this.enableMemory,
      memoryFullInjectionTypes: Set<MemoryType>.unmodifiable(
        memoryFullInjectionTypes ?? this.memoryFullInjectionTypes,
      ),
      autoOrganizeMemory: autoOrganizeMemory ?? this.autoOrganizeMemory,
      memoryOrganizeEveryNTurns:
          memoryOrganizeEveryNTurns ?? this.memoryOrganizeEveryNTurns,
      memorySmartAddMode: memorySmartAddMode ?? this.memorySmartAddMode,
      memoryWriteScope: memoryWriteScope ?? this.memoryWriteScope,
      allowPastConversationRecall:
          allowPastConversationRecall ?? this.allowPastConversationRecall,
      generateConversationSummary:
          generateConversationSummary ?? this.generateConversationSummary,
      recentChatsSummaryMessageCount:
          recentChatsSummaryMessageCount ?? this.recentChatsSummaryMessageCount,
      appendCurrentTimeToUserMessage:
          appendCurrentTimeToUserMessage ?? this.appendCurrentTimeToUserMessage,
      useIso8601TimeFormat: useIso8601TimeFormat ?? this.useIso8601TimeFormat,
      presetMessages: presetMessages ?? this.presetMessages,
      regexRules: regexRules ?? this.regexRules,
      enableProactiveCare: enableProactiveCare ?? this.enableProactiveCare,
      proactiveCarePrompt: proactiveCarePrompt ?? this.proactiveCarePrompt,
      proactiveCareDecisionPrompt:
          proactiveCareDecisionPrompt ?? this.proactiveCareDecisionPrompt,
      proactiveCareDecisionHistoryMessageLimit:
          clearProactiveCareDecisionHistoryMessageLimit
          ? null
          : _normalizeProactiveCareHistoryLimit(
              proactiveCareDecisionHistoryMessageLimit ??
                  this.proactiveCareDecisionHistoryMessageLimit,
            ),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'harnessUrl': harnessUrl,
    'harnessConnectionMode': harnessConnectionMode.name,
    'harnessTailcatAddress': harnessTailcatAddress,
    'harnessTailcatPort': harnessTailcatPort,
    'avatar': avatar,
    'useAssistantAvatar': useAssistantAvatar,
    'useAssistantName': useAssistantName,
    'chatModelProvider': chatModelProvider,
    'chatModelId': chatModelId,
    'temperature': temperature,
    'topP': topP,
    'contextMessageSize': contextMessageSize,
    'limitContextMessages': limitContextMessages,
    'streamOutput': streamOutput,
    'reasoning': reasoning?.toJson(),
    'maxTokens': maxTokens,
    'systemPrompt': systemPrompt,
    'allowConversationSystemPrompt': allowConversationSystemPrompt,
    'allowConversationPromptInjection': allowConversationPromptInjection,
    'messageTemplate': messageTemplate,
    'searchEnabled': searchEnabled,
    'suggestionsEnabled': suggestionsEnabled,
    'mcpServerIds': mcpServerIds,
    'allowConversationMcp': allowConversationMcp,
    'localToolIds': localToolIds,
    'imageModelProvider': imageModelProvider,
    'imageModelId': imageModelId,
    'subagentModelProvider': subagentModelProvider,
    'subagentModelId': subagentModelId,
    'subagentEscalation': subagentEscalation.name,
    'subagentTargetIds': subagentTargetIds,
    'subagentDepth': subagentDepth,
    'description': description,
    'defaultWorkspaceId': defaultWorkspaceId,
    'defaultWorkspaceSetup': defaultWorkspaceSetup.name,
    'skillIds': skillIds,
    'healthDataTypeIds': healthDataTypeIds,
    'background': background,
    'useGradientBackground': useGradientBackground,
    'gradientBackgroundAnimated': gradientBackgroundAnimated,
    'gradientBackgroundPhase': gradientBackgroundPhase,
    'gradientBackgroundOffsetX': gradientBackgroundOffsetX,
    'gradientBackgroundOffsetY': gradientBackgroundOffsetY,
    'customHeaders': customHeaders,
    'customBody': customBody,
    'enableMemory': enableMemory,
    'memoryFullInjectionTypes': MemoryType.values
        .where(memoryFullInjectionTypes.contains)
        .map(MemoryEntry.typeToString)
        .toList(),
    'autoOrganizeMemory': autoOrganizeMemory,
    'memoryOrganizeEveryNTurns': memoryOrganizeEveryNTurns,
    'memorySmartAddMode': memorySmartAddModeToString(memorySmartAddMode),
    'memoryWriteScope': memoryWriteScopeToString(memoryWriteScope),
    'allowPastConversationRecall': allowPastConversationRecall,
    'generateConversationSummary': generateConversationSummary,
    'recentChatsSummaryMessageCount': recentChatsSummaryMessageCount,
    'appendCurrentTimeToUserMessage': appendCurrentTimeToUserMessage,
    'useIso8601TimeFormat': useIso8601TimeFormat,
    'presetMessages': PresetMessage.encodeList(presetMessages),
    'regexRules': regexRules.map((e) => e.toJson()).toList(),
    'enableProactiveCare': enableProactiveCare,
    'proactiveCarePrompt': proactiveCarePrompt,
    'proactiveCareDecisionPrompt': proactiveCareDecisionPrompt,
    'proactiveCareDecisionHistoryMessageLimit':
        proactiveCareDecisionHistoryMessageLimit,
  };

  static ReasoningRequest? _readReasoning(Object? value) {
    if (value is Map) return ReasoningRequest.fromJson(value);
    return null;
  }

  static String? _nonEmptyHarnessUrl(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Clamps a stored peer port to a usable TCP port, defaulting to the
  /// plugin's port when the payload has none (or an unusable one).
  static int _readHarnessTailcatPort(Object? value) {
    final port = value is num ? value.toInt() : null;
    if (port == null || port < 1 || port > 65535) {
      return kHarnessTailcatDefaultPort;
    }
    return port;
  }

  static double _readGradientBackgroundPhase(Object? value) =>
      value is num && value.isFinite && value >= 0
      ? value.toDouble()
      : defaultGradientBackgroundPhase;

  static Assistant fromJson(Map<String, dynamic> json) => Assistant(
    id: json['id'] as String,
    name: (json['name'] as String?) ?? '',
    kind:
        AssistantKind.values
            .where((value) => value.name == json['kind'])
            .firstOrNull ??
        AssistantKind.local,
    harnessUrl: _nonEmptyHarnessUrl(json['harnessUrl']),
    harnessConnectionMode:
        HarnessConnectionMode.values
            .where((value) => value.name == json['harnessConnectionMode'])
            .firstOrNull ??
        HarnessConnectionMode.publicLink,
    harnessTailcatAddress: _nonEmptyHarnessUrl(json['harnessTailcatAddress']),
    harnessTailcatPort: _readHarnessTailcatPort(json['harnessTailcatPort']),
    avatar: json['avatar'] as String?,
    useAssistantAvatar: json['useAssistantAvatar'] as bool? ?? false,
    useAssistantName: json['useAssistantName'] as bool? ?? false,
    chatModelProvider: json['chatModelProvider'] as String?,
    chatModelId: json['chatModelId'] as String?,
    temperature: (json['temperature'] as num?)?.toDouble(),
    topP: (json['topP'] as num?)?.toDouble(),
    contextMessageSize: (json['contextMessageSize'] as num?)?.toInt() ?? 64,
    limitContextMessages: json['limitContextMessages'] as bool? ?? false,
    streamOutput: json['streamOutput'] as bool? ?? true,
    reasoning: _readReasoning(json['reasoning']),
    maxTokens: (json['maxTokens'] as num?)?.toInt(),
    systemPrompt: (json['systemPrompt'] as String?) ?? '',
    allowConversationSystemPrompt:
        (json['allowConversationSystemPrompt'] as bool?) ?? false,
    allowConversationPromptInjection:
        (json['allowConversationPromptInjection'] as bool?) ?? false,
    messageTemplate: (json['messageTemplate'] as String?) ?? '{{ message }}',
    searchEnabled: json['searchEnabled'] as bool? ?? false,
    suggestionsEnabled: json['suggestionsEnabled'] as bool? ?? true,
    mcpServerIds:
        (json['mcpServerIds'] as List?)?.cast<String>() ?? const <String>[],
    allowConversationMcp: json['allowConversationMcp'] as bool? ?? false,
    localToolIds:
        (json['localToolIds'] as List?)?.cast<String>() ?? const <String>[],
    imageModelProvider: json['imageModelProvider'] as String?,
    imageModelId: json['imageModelId'] as String?,
    subagentModelProvider: json['subagentModelProvider'] as String?,
    subagentModelId: json['subagentModelId'] as String?,
    subagentEscalation:
        SubagentEscalation.values
            .where((value) => value.name == json['subagentEscalation'])
            .firstOrNull ??
        SubagentEscalation.ask,
    subagentTargetIds:
        (json['subagentTargetIds'] as List?)?.cast<String>() ??
        const <String>[],
    subagentDepth: (json['subagentDepth'] as int? ?? kSubagentDepthMin).clamp(
      kSubagentDepthMin,
      kSubagentDepthMax,
    ),
    description: (json['description'] as String?) ?? '',
    defaultWorkspaceId: json['defaultWorkspaceId'] as String?,
    defaultWorkspaceSetup:
        DefaultWorkspaceSetup.values
            .where((value) => value.name == json['defaultWorkspaceSetup'])
            .firstOrNull ??
        ((json['defaultWorkspaceId'] as String?)?.isNotEmpty == true
            ? DefaultWorkspaceSetup.completed
            : DefaultWorkspaceSetup.suggest),
    skillIds: json['skillIds'] == null
        ? null
        : (json['skillIds'] as List).map((e) => e.toString()).toList(),
    healthDataTypeIds: HealthDataTypeIds.parseStoredIds(
      json['healthDataTypeIds'],
    ),
    background: json['background'] as String?,
    useGradientBackground: json['useGradientBackground'] as bool? ?? false,
    gradientBackgroundAnimated:
        json['gradientBackgroundAnimated'] as bool? ?? true,
    gradientBackgroundPhase: _readGradientBackgroundPhase(
      json['gradientBackgroundPhase'],
    ),
    gradientBackgroundOffsetX:
        ((json['gradientBackgroundOffsetX'] as num?)?.toDouble() ?? 0).clamp(
          -1.0,
          1.0,
        ),
    gradientBackgroundOffsetY:
        ((json['gradientBackgroundOffsetY'] as num?)?.toDouble() ?? 0).clamp(
          -1.0,
          1.0,
        ),
    customHeaders: (() {
      final raw = json['customHeaders'];
      if (raw is List) {
        return raw
            .whereType<Map>()
            .map(
              (e) => {
                'name': (e['name'] ?? e['key'] ?? '').toString(),
                'value': (e['value'] ?? '').toString(),
              },
            )
            .toList();
      }
      return const <Map<String, String>>[];
    })(),
    customBody: (() {
      final raw = json['customBody'];
      if (raw is List) {
        return raw
            .whereType<Map>()
            .map(
              (e) => {
                'key': (e['key'] ?? e['name'] ?? '').toString(),
                'value': (e['value'] ?? '').toString(),
              },
            )
            .toList();
      }
      return const <Map<String, String>>[];
    })(),
    enableMemory: json['enableMemory'] as bool? ?? false,
    memoryFullInjectionTypes: Set<MemoryType>.unmodifiable(
      MemoryType.values.where(
        (type) =>
            (json['memoryFullInjectionTypes'] as List?)?.contains(
              MemoryEntry.typeToString(type),
            ) ??
            false,
      ),
    ),
    autoOrganizeMemory: json['autoOrganizeMemory'] as bool? ?? false,
    memoryOrganizeEveryNTurns: (() {
      final raw = (json['memoryOrganizeEveryNTurns'] as num?)?.toInt();
      if (raw == null ||
          raw < minMemoryOrganizeEveryNTurns ||
          raw > maxMemoryOrganizeEveryNTurns) {
        return defaultMemoryOrganizeEveryNTurns;
      }
      return raw;
    })(),
    memorySmartAddMode: memorySmartAddModeFromString(
      json['memorySmartAddMode'] as String?,
    ),
    memoryWriteScope: memoryWriteScopeFromString(
      json['memoryWriteScope'] as String?,
    ),
    // Legacy `enableRecentChatsReference` maps onto allowPastConversationRecall.
    allowPastConversationRecall:
        json['allowPastConversationRecall'] as bool? ??
        json['enableRecentChatsReference'] as bool? ??
        false,
    generateConversationSummary:
        json['generateConversationSummary'] as bool? ?? false,
    recentChatsSummaryMessageCount: (() {
      final raw = (json['recentChatsSummaryMessageCount'] as num?)?.toInt();
      if (raw == null || raw < 1) {
        return defaultRecentChatsSummaryMessageCount;
      }
      return raw;
    })(),
    appendCurrentTimeToUserMessage:
        json['appendCurrentTimeToUserMessage'] as bool? ?? false,
    useIso8601TimeFormat: json['useIso8601TimeFormat'] as bool? ?? false,
    presetMessages: (() {
      try {
        return PresetMessage.decodeList(json['presetMessages']);
      } catch (_) {
        return const <PresetMessage>[];
      }
    })(),
    regexRules: (() {
      final raw = json['regexRules'];
      if (raw is List) {
        return raw
            .whereType<Map>()
            .map((e) => AssistantRegex.fromJson(e.cast<String, dynamic>()))
            .toList();
      }
      return const <AssistantRegex>[];
    })(),
    enableProactiveCare: json['enableProactiveCare'] as bool? ?? false,
    proactiveCarePrompt: (json['proactiveCarePrompt'] as String?) ?? '',
    proactiveCareDecisionPrompt:
        (json['proactiveCareDecisionPrompt'] as String?) ?? '',
    proactiveCareDecisionHistoryMessageLimit:
        _normalizeProactiveCareHistoryLimit(
          (json['proactiveCareDecisionHistoryMessageLimit'] as num?)?.toInt(),
        ),
  );

  static String memorySmartAddModeToString(MemorySmartAddMode mode) {
    switch (mode) {
      case MemorySmartAddMode.batched:
        return 'batched';
      case MemorySmartAddMode.perItem:
        return 'perItem';
    }
  }

  static MemorySmartAddMode memorySmartAddModeFromString(String? value) {
    switch (value) {
      case 'perItem':
        return MemorySmartAddMode.perItem;
      case 'batched':
      default:
        return MemorySmartAddMode.batched;
    }
  }

  static String memoryWriteScopeToString(MemoryWriteScope scope) {
    switch (scope) {
      case MemoryWriteScope.alwaysGlobal:
        return 'alwaysGlobal';
      case MemoryWriteScope.alwaysAssistant:
        return 'alwaysAssistant';
      case MemoryWriteScope.toolDefaultGlobal:
        return 'toolDefaultGlobal';
      case MemoryWriteScope.toolDefaultAssistant:
        return 'toolDefaultAssistant';
    }
  }

  static MemoryWriteScope memoryWriteScopeFromString(String? value) {
    switch (value) {
      case 'alwaysAssistant':
        return MemoryWriteScope.alwaysAssistant;
      case 'toolDefaultGlobal':
        return MemoryWriteScope.toolDefaultGlobal;
      case 'toolDefaultAssistant':
        return MemoryWriteScope.toolDefaultAssistant;
      case 'alwaysGlobal':
      default:
        return MemoryWriteScope.alwaysGlobal;
    }
  }

  static String encodeList(List<Assistant> list) =>
      jsonEncode(list.map((e) => e.toJson()).toList());
  static List<Assistant> decodeList(String raw) {
    try {
      final arr = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in arr) Assistant.fromJson(e as Map<String, dynamic>),
      ];
    } catch (_) {
      return const <Assistant>[];
    }
  }
}
