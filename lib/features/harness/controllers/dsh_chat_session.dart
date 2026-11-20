import 'package:flutter/foundation.dart';

/// Flutter-side view models for one open DeepSeek Harness session.
///
/// This file is deliberately free of every network type: the chat surface is
/// built against these plain, immutable view models so it can be tested with a
/// fake and so the stage-2 binding is a thin adapter over the real client
/// (`lib/core/dsh`, see `docs/cuplivo-dsh/client-api.md`). The server owns every
/// session, transcript and setting; nothing here is persisted by Cuplivo.

// ---------------------------------------------------------------------------
// Model catalog
// ---------------------------------------------------------------------------

/// One selectable reasoning effort advertised by the Host's model catalog.
///
/// [id] is the wire value (`session/selectModel.reasoningEffort`), [name] is the
/// display text the catalog supplies. Cuplivo never invents an effort: a model
/// without efforts offers no reasoning control.
@immutable
class DshReasoningEffort {
  const DshReasoningEffort({
    required this.id,
    required this.name,
    this.description,
  });

  final String id;
  final String name;
  final String? description;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshReasoningEffort &&
          other.id == id &&
          other.name == name &&
          other.description == description;

  @override
  int get hashCode => Object.hash(id, name, description);

  @override
  String toString() => 'DshReasoningEffort($id)';
}

/// One model the connected Host advertises.
@immutable
class DshModelOption {
  const DshModelOption({
    required this.id,
    required this.name,
    this.description,
    this.badge,
    this.reasoningEfforts = const <DshReasoningEffort>[],
    this.defaultReasoningEffortId,
  });

  final String id;

  /// Display name from the catalog; the picker falls back to [id] when empty.
  final String name;

  final String? description;

  /// Optional catalog badge text (e.g. a beta/experimental marker).
  final String? badge;

  final List<DshReasoningEffort> reasoningEfforts;

  /// The catalog's starting effort for this model, if it advertises one.
  final String? defaultReasoningEffortId;

  bool get supportsReasoning => reasoningEfforts.isNotEmpty;

  String get displayName => name.trim().isEmpty ? id : name;

  DshReasoningEffort? effortById(String? effortId) {
    if (effortId == null || effortId.isEmpty) return null;
    for (final effort in reasoningEfforts) {
      if (effort.id == effortId) return effort;
    }
    return null;
  }

  /// The effort the Host would use for a session that never chose one.
  ///
  /// Mirrors the reference client's `startingEffort`: the catalog default when
  /// advertised, otherwise `medium`, otherwise the first non-`off` effort, as
  /// the catalog is the only truth about what this model accepts.
  DshReasoningEffort? get defaultEffort {
    final declared = effortById(defaultReasoningEffortId);
    if (declared != null) return declared;
    final medium = effortById('medium');
    if (medium != null) return medium;
    for (final effort in reasoningEfforts) {
      if (effort.id != 'off') return effort;
    }
    return reasoningEfforts.isEmpty ? null : reasoningEfforts.first;
  }

  /// Resolves a stored effort id to one this model still advertises.
  ///
  /// A stored value that is no longer in the catalog never reaches the wire:
  /// the reference falls back to the model's starting effort instead.
  DshReasoningEffort? resolveEffort(String? effortId) =>
      effortById(effortId) ?? defaultEffort;

  DshModelOption copyWith({
    String? id,
    String? name,
    String? description,
    String? badge,
    List<DshReasoningEffort>? reasoningEfforts,
    String? defaultReasoningEffortId,
  }) {
    return DshModelOption(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      badge: badge ?? this.badge,
      reasoningEfforts: reasoningEfforts ?? this.reasoningEfforts,
      defaultReasoningEffortId:
          defaultReasoningEffortId ?? this.defaultReasoningEffortId,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshModelOption &&
          other.id == id &&
          other.name == name &&
          other.description == description &&
          other.badge == badge &&
          listEquals(other.reasoningEfforts, reasoningEfforts) &&
          other.defaultReasoningEffortId == defaultReasoningEffortId;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    description,
    badge,
    Object.hashAll(reasoningEfforts),
    defaultReasoningEffortId,
  );

  @override
  String toString() => 'DshModelOption($id)';
}

/// One provider (a Host plugin route, e.g. `deepseek`) and its models.
///
/// [failureMessage] is set when the Host could load the provider's route but
/// its catalog failed; the picker then renders the provider as a failed entry
/// carrying the Host's message instead of silently dropping it.
@immutable
class DshModelProviderGroup {
  const DshModelProviderGroup({
    required this.id,
    required this.name,
    this.models = const <DshModelOption>[],
    this.failureMessage,
  });

  final String id;
  final String name;
  final List<DshModelOption> models;

  /// Non-null when this provider failed to list its models.
  final String? failureMessage;

  bool get failed => (failureMessage ?? '').isNotEmpty;

  String get displayName => name.trim().isEmpty ? id : name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshModelProviderGroup &&
          other.id == id &&
          other.name == name &&
          listEquals(other.models, models) &&
          other.failureMessage == failureMessage;

  @override
  int get hashCode =>
      Object.hash(id, name, Object.hashAll(models), failureMessage);

  @override
  String toString() => 'DshModelProviderGroup($id, ${models.length} models)';
}

/// A provider row the Host could not route at all (`modelCatalog.failures`).
@immutable
class DshModelCatalogFailure {
  const DshModelCatalogFailure({
    required this.id,
    required this.name,
    this.message,
  });

  final String id;
  final String name;
  final String? message;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshModelCatalogFailure &&
          other.id == id &&
          other.name == name &&
          other.message == message;

  @override
  int get hashCode => Object.hash(id, name, message);
}

/// The current (or default) provider/model/effort of a session.
@immutable
class DshModelSelection {
  const DshModelSelection({
    required this.providerId,
    required this.modelId,
    this.reasoningEffortId,
  });

  final String providerId;
  final String modelId;
  final String? reasoningEffortId;

  DshModelSelection copyWith({
    String? providerId,
    String? modelId,
    String? reasoningEffortId,
  }) {
    return DshModelSelection(
      providerId: providerId ?? this.providerId,
      modelId: modelId ?? this.modelId,
      reasoningEffortId: reasoningEffortId ?? this.reasoningEffortId,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshModelSelection &&
          other.providerId == providerId &&
          other.modelId == modelId &&
          other.reasoningEffortId == reasoningEffortId;

  @override
  int get hashCode => Object.hash(providerId, modelId, reasoningEffortId);

  @override
  String toString() =>
      'DshModelSelection($providerId/$modelId'
      '${reasoningEffortId == null ? '' : ':$reasoningEffortId'})';
}

/// The Host's model catalog, exactly as `session/modelCatalog` reports it.
@immutable
class DshModelCatalog {
  const DshModelCatalog({
    this.groups = const <DshModelProviderGroup>[],
    this.failures = const <DshModelCatalogFailure>[],
    this.defaultSelection,
    this.isLoading = false,
  });

  final List<DshModelProviderGroup> groups;

  /// Providers the Host could not route; rendered as disabled rows with the
  /// Host's message (capability parity: a failure is never silently hidden).
  final List<DshModelCatalogFailure> failures;

  /// The catalog's default selection, used by a session that never chose one.
  final DshModelSelection? defaultSelection;

  final bool isLoading;

  bool get isEmpty => groups.every((group) => group.models.isEmpty);

  DshModelProviderGroup? groupById(String providerId) {
    for (final group in groups) {
      if (group.id == providerId) return group;
    }
    return null;
  }

  DshModelOption? modelById(String providerId, String modelId) {
    final group = groupById(providerId);
    if (group == null) return null;
    for (final model in group.models) {
      if (model.id == modelId) return model;
    }
    return null;
  }

  /// Looks up the model of [selection], falling back to the catalog default.
  DshModelOption? modelFor(DshModelSelection? selection) {
    final target = selection ?? defaultSelection;
    if (target == null) return null;
    return modelById(target.providerId, target.modelId);
  }

  DshModelProviderGroup? groupFor(DshModelSelection? selection) {
    final target = selection ?? defaultSelection;
    if (target == null) return null;
    return groupById(target.providerId);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshModelCatalog &&
          listEquals(other.groups, groups) &&
          listEquals(other.failures, failures) &&
          other.defaultSelection == defaultSelection &&
          other.isLoading == isLoading;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(groups),
    Object.hashAll(failures),
    defaultSelection,
    isLoading,
  );
}

// ---------------------------------------------------------------------------
// Agent presets
// ---------------------------------------------------------------------------

/// One Agent preset the Host's `agentPresets/list` roster advertises.
///
/// The four shipped presets publish no display copy; Cuplivo localizes them by
/// [id]. A plugin declaration that names itself owns its name and description,
/// and those are always rendered verbatim.
@immutable
class DshAgentPresetOption {
  const DshAgentPresetOption({
    required this.id,
    this.name,
    this.description,
    this.isDefault = false,
    this.broken,
  });

  /// Stable identifier and the value `agentPresets/select` records.
  final String id;

  /// Display name the preset published; null for the shipped presets.
  final String? name;

  /// One sentence on what this preset is for; null when unpublished.
  final String? description;

  /// Whether a Session naming no preset composes this one.
  final bool isDefault;

  /// Why this preset cannot start a Session; null when it can.
  final String? broken;

  bool get isBroken => (broken ?? '').trim().isNotEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshAgentPresetOption &&
          other.id == id &&
          other.name == name &&
          other.description == description &&
          other.isDefault == isDefault &&
          other.broken == broken;

  @override
  int get hashCode => Object.hash(id, name, description, isDefault, broken);

  @override
  String toString() => 'DshAgentPresetOption($id)';
}

/// The roster and the preset the open Session runs.
///
/// Null means the connected Host composes no preset roster at all — the
/// composer then hides the control instead of inventing a default.
@immutable
class DshAgentPresetState {
  const DshAgentPresetState({
    required this.options,
    required this.currentId,
    required this.defaultId,
    required this.canSelect,
    this.isChanging = false,
  });

  final List<DshAgentPresetOption> options;

  /// The preset the open Session runs, or the Host-effective default while a
  /// fresh Session records none yet.
  final String currentId;

  /// The roster's default row id; null for an empty roster.
  final String? defaultId;

  /// True while the Session has not started its first turn — the only window
  /// in which the Host accepts a preset switch.
  final bool canSelect;

  final bool isChanging;

  DshAgentPresetOption? optionFor(String id) {
    for (final option in options) {
      if (option.id == id) return option;
    }
    return null;
  }

  DshAgentPresetOption? get currentOption => optionFor(currentId);

  DshAgentPresetState copyWith({
    List<DshAgentPresetOption>? options,
    String? currentId,
    String? defaultId,
    bool? canSelect,
    bool? isChanging,
  }) {
    return DshAgentPresetState(
      options: options ?? this.options,
      currentId: currentId ?? this.currentId,
      defaultId: defaultId ?? this.defaultId,
      canSelect: canSelect ?? this.canSelect,
      isChanging: isChanging ?? this.isChanging,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshAgentPresetState &&
          listEquals(other.options, options) &&
          other.currentId == currentId &&
          other.defaultId == defaultId &&
          other.canSelect == canSelect &&
          other.isChanging == isChanging;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(options),
    currentId,
    defaultId,
    canSelect,
    isChanging,
  );
}

// ---------------------------------------------------------------------------
// Permissions
// ---------------------------------------------------------------------------

/// One permission preset the Host's `permissionPresets/catalog` advertises.
///
/// The value is a server identifier (`read-only`, `workspace-write`,
/// `danger-full-access`, …) and the name/description are the Host's own display
/// text when it supplies one — Cuplivo's localized names are only a fallback.
@immutable
class DshPermissionOption {
  const DshPermissionOption({
    required this.value,
    required this.name,
    this.description,
    this.requiresRiskConfirmation = false,
  });

  final String value;
  final String name;
  final String? description;

  /// Full access (and the experimental auto review) is destructive enough that
  /// the official UI asks for an explicit acknowledgement first; the value set
  /// is decided by the caller, which knows the Host's catalog.
  final bool requiresRiskConfirmation;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshPermissionOption &&
          other.value == value &&
          other.name == name &&
          other.description == description &&
          other.requiresRiskConfirmation == requiresRiskConfirmation;

  @override
  int get hashCode =>
      Object.hash(value, name, description, requiresRiskConfirmation);

  @override
  String toString() => 'DshPermissionOption($value)';
}

/// The session's permission presets and its current value.
///
/// Null means the connected Host composes no permission service at all — the
/// chat then hides the control instead of inventing a default.
@immutable
class DshPermissionState {
  const DshPermissionState({
    required this.options,
    required this.currentValue,
    this.isChanging = false,
  });

  final List<DshPermissionOption> options;

  /// The `permissions` projection's `currentValue`. May be a value the catalog
  /// does not list (`auto`, `custom`); the control then shows the raw value.
  final String currentValue;

  final bool isChanging;

  /// The catalog option for a raw value, when it lists it.
  DshPermissionOption? optionFor(String value) {
    for (final option in options) {
      if (option.value == value) return option;
    }
    return null;
  }

  DshPermissionOption? get currentOption => optionFor(currentValue);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshPermissionState &&
          listEquals(other.options, options) &&
          other.currentValue == currentValue &&
          other.isChanging == isChanging;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(options), currentValue, isChanging);
}

// ---------------------------------------------------------------------------
// Transcript
// ---------------------------------------------------------------------------

/// A reasoning block inside one assistant message.
@immutable
class DshReasoningSegment {
  const DshReasoningSegment({
    required this.text,
    this.startedAt,
    this.finishedAt,
  });

  final String text;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  bool get isStreaming => startedAt != null && finishedAt == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshReasoningSegment &&
          other.text == text &&
          other.startedAt == startedAt &&
          other.finishedAt == finishedAt;

  @override
  int get hashCode => Object.hash(text, startedAt, finishedAt);
}

/// A tool call/result pair as the timeline renders it.
@immutable
class DshToolCall {
  const DshToolCall({
    required this.id,
    required this.name,
    this.arguments = const <String, dynamic>{},
    this.resultText,
    this.isRunning = false,
    this.isError = false,
  });

  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  final String? resultText;
  final bool isRunning;
  final bool isError;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshToolCall &&
          other.id == id &&
          other.name == name &&
          mapEquals(other.arguments, arguments) &&
          other.resultText == resultText &&
          other.isRunning == isRunning &&
          other.isError == isError;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    Object.hashAllUnordered(
      arguments.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    resultText,
    isRunning,
    isError,
  );
}

/// Token usage the Host reports for a finished turn.
@immutable
class DshUsage {
  const DshUsage({this.promptTokens, this.completionTokens, this.totalTokens});

  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshUsage &&
          other.promptTokens == promptTokens &&
          other.completionTokens == completionTokens &&
          other.totalTokens == totalTokens;

  @override
  int get hashCode => Object.hash(promptTokens, completionTokens, totalTokens);
}

/// One rendered entry of the remote session log.
/// One attachment shown on a user prompt row, already resolved for rendering.
///
/// The transcript never carries wire types: [dataUri] is filled only after the
/// authenticated `session/attachment` fetch succeeded, so the shared chat
/// renderer can draw inline images with no remote provider.
@immutable
class DshMessageAttachment {
  const DshMessageAttachment({
    required this.id,
    this.name,
    this.mediaType,
    this.isImage = false,
    this.dataUri,
    this.unavailable = false,
  });

  final String id;
  final String? name;
  final String? mediaType;
  final bool isImage;

  /// `data:<mime>;base64,…` when the bytes were fetched, else null.
  final String? dataUri;

  /// True when this image could not be fetched (or is still fetching).
  final bool unavailable;

  bool get isRenderableImage => isImage && (dataUri?.isNotEmpty ?? false);
}

/// The Host's `contextPressure` readout for the composer ring.
@immutable
class DshContextPressure {
  const DshContextPressure({
    this.pressureTokens,
    this.projectedTokens,
    this.contextWindow,
  });

  final int? pressureTokens;
  final int? projectedTokens;
  final int? contextWindow;

  bool get hasWindow => (contextWindow ?? 0) > 0;
}

/// The Host's composer image budget (`imageLimits` projection).
@immutable
class DshImageLimits {
  const DshImageLimits({
    this.maxImageBytes,
    this.maxImagesPerMessage,
    this.maxMessageImageBytes,
    this.maxImagePixels,
    this.maxImageDimension,
    this.mediaTypes = const <String>[],
  });

  final int? maxImageBytes;
  final int? maxImagesPerMessage;
  final int? maxMessageImageBytes;
  final int? maxImagePixels;
  final int? maxImageDimension;
  final List<String> mediaTypes;
}

/// One command in the Host's `commands/list` catalog.
@immutable
class DshSlashCommand {
  const DshSlashCommand({
    required this.name,
    this.description,
    this.inputHint,
    this.takesAttachments = false,
  });

  /// Lowercase name without the leading slash.
  final String name;
  final String? description;

  /// The Host's argument hint; null ends the command (it runs as-is).
  final String? inputHint;
  final bool takesAttachments;

  bool get takesInput => (inputHint ?? '').trim().isNotEmpty;
}

/// The in-band outcome of a `commands/execute` call.
@immutable
class DshCommandResult {
  const DshCommandResult({required this.success, this.text});

  final bool success;
  final String? text;
}

/// One attachment the composer prepared for `session/prompt`.
@immutable
class DshPromptAttachment {
  const DshPromptAttachment.image({
    required this.bytes,
    this.name,
    this.mediaType,
  }) : receiptId = '',
       isImage = true;

  const DshPromptAttachment.file({
    required this.receiptId,
    this.name,
    this.mediaType,
  }) : bytes = null,
       isImage = false;

  /// Upload receipt id for files; empty for inline images.
  final String receiptId;
  final List<int>? bytes;
  final String? name;
  final String? mediaType;
  final bool isImage;
}

sealed class DshChatItem {
  const DshChatItem({required this.id, this.timestamp});

  /// The Host's stable id for this entry (or the client-side request id for an
  /// optimistic user bubble that has not been echoed back yet).
  final String id;

  /// Epoch-derived timestamp the renderer shows; null when the Host did not
  /// report one.
  final DateTime? timestamp;
}

/// A user prompt, either from history or optimistically on screen.
final class DshUserMessageItem extends DshChatItem {
  const DshUserMessageItem({
    required super.id,
    super.timestamp,
    required this.text,
    this.attachments = const <DshMessageAttachment>[],
    this.pending = false,
    this.failed = false,
  });

  final String text;

  /// True while the prompt is accepted-but-not-yet-echoed by the Host.
  final bool pending;

  /// True when the Host rejected the prompt; the composer restores the draft.
  final bool failed;

  /// Attachments that travelled with this prompt (image inline, files promoted
  /// to upload receipts), resolved for the transcript renderer.
  final List<DshMessageAttachment> attachments;
}

/// One assistant reply (a durable message or the live streaming draft).
final class DshAssistantMessageItem extends DshChatItem {
  const DshAssistantMessageItem({
    required super.id,
    super.timestamp,
    this.text = '',
    this.reasoning = const <DshReasoningSegment>[],
    this.tools = const <DshToolCall>[],
    this.isStreaming = false,
    this.interrupted = false,
    this.modelId,
    this.providerId,
    this.usage,
    this.failureMessage,
  });

  final String text;
  final List<DshReasoningSegment> reasoning;
  final List<DshToolCall> tools;
  final bool isStreaming;

  /// The turn was cut (cancel/error) but the delivered prefix stays visible.
  final bool interrupted;

  final String? modelId;
  final String? providerId;
  final DshUsage? usage;

  /// A turn error attached to this reply, rendered as a notice under it.
  final String? failureMessage;
}

/// A non-message row of the session log (turn error/cancel/retry, notice).
enum DshNoticeKind { info, error, cancelled }

final class DshNoticeItem extends DshChatItem {
  const DshNoticeItem({
    required super.id,
    super.timestamp,
    required this.kind,
    required this.text,
  });

  final DshNoticeKind kind;
  final String text;
}

// ---------------------------------------------------------------------------
// Pending host requests (approvals and user questions)
// ---------------------------------------------------------------------------

/// An approval/ask-user waterfall the Host is blocking on.
///
/// These are host requests, not transcript events: they must be answered for
/// the turn to continue, and the UI never silently defaults them.
@immutable
class DshPendingApproval {
  const DshPendingApproval({
    required this.id,
    required this.toolName,
    this.reason,
    this.callId,
  });

  /// The `$events` waterfall id; answers are bound to it.
  final String id;
  final String toolName;
  final String? reason;
  final String? callId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshPendingApproval &&
          other.id == id &&
          other.toolName == toolName &&
          other.reason == reason &&
          other.callId == callId;

  @override
  int get hashCode => Object.hash(id, toolName, reason, callId);
}

@immutable
class DshQuestionOption {
  const DshQuestionOption({required this.label, this.description});

  final String label;
  final String? description;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshQuestionOption &&
          other.label == label &&
          other.description == description;

  @override
  int get hashCode => Object.hash(label, description);
}

@immutable
class DshUserQuestion {
  const DshUserQuestion({
    required this.id,
    required this.question,
    this.header,
    this.detail,
    this.options = const <DshQuestionOption>[],
    this.multiSelect = false,
  });

  final String id;
  final String question;
  final String? header;
  final String? detail;
  final List<DshQuestionOption> options;
  final bool multiSelect;

  bool get hasOptions => options.isNotEmpty;
}

@immutable
class DshPendingQuestion {
  const DshPendingQuestion({required this.id, required this.questions});

  /// The `$events` waterfall id.
  final String id;
  final List<DshUserQuestion> questions;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshPendingQuestion &&
          other.id == id &&
          listEquals(other.questions, questions);

  @override
  int get hashCode => Object.hash(id, Object.hashAll(questions));
}

/// One answer to one question of a [DshPendingQuestion].
@immutable
class DshQuestionAnswer {
  const DshQuestionAnswer({
    required this.questionId,
    this.selected = const <String>[],
    this.custom,
  });

  final String questionId;

  /// The option labels the user picked (the wire encodes labels, not ids).
  final List<String> selected;

  /// Free-form answer when the Host accepts one.
  final String? custom;
}

// ---------------------------------------------------------------------------
// Session state and the controller seam
// ---------------------------------------------------------------------------

/// Why the live link is currently unusable, mirrored from the gateway's
/// `DshFailure` so the chat can render a localized sentence without importing
/// the protocol client.
enum DshConnectionProblem {
  notConfigured,
  unreachable,
  auth,
  protocol,
  unsupported,
  unknown,
}

/// Everything the chat surface needs to paint one frame of an open session.
@immutable
class DshChatViewState {
  const DshChatViewState({
    this.items = const <DshChatItem>[],
    this.title,
    this.workspaceLabel,
    this.running = false,
    this.isSending = false,
    this.queuedPromptCount = 0,
    this.stale = false,
    this.connectionError,
    this.connectionProblem,
    this.modelSelection,
    this.modelCatalog = const DshModelCatalog(),
    this.permissions,
    this.agentPresets,
    this.approvals = const <DshPendingApproval>[],
    this.questions = const <DshPendingQuestion>[],
    this.contextPressure,
    this.imageLimits,
    this.commands = const <DshSlashCommand>[],
  });

  /// The session log projection, oldest first.
  final List<DshChatItem> items;

  /// Session title for the app bar; null when the Host has none yet.
  final String? title;

  /// Human-readable workspace/cwd label for the plus menu's 工作区 row.
  final String? workspaceLabel;

  /// A turn is executing on the Host.
  final bool running;

  /// A prompt send is in flight (accepted/rejected not known yet).
  final bool isSending;

  /// Prompts the Host queued behind the running turn.
  final int queuedPromptCount;

  /// The link is lost and the transcript is the last frame, not live.
  final bool stale;

  /// A connection-level failure sentence, when one is in effect.
  final String? connectionError;

  /// A machine-readable link failure; the chat localizes it with Cuplivo's own
  /// DSH error strings. Preferred over [connectionError] when both are set.
  final DshConnectionProblem? connectionProblem;

  /// The session's model/effort selection (`modelSelection` projection).
  final DshModelSelection? modelSelection;

  final DshModelCatalog modelCatalog;
  final DshPermissionState? permissions;

  /// The Agent-preset roster and the open Session's preset; null when the Host
  /// composes no preset roster.
  final DshAgentPresetState? agentPresets;
  final List<DshPendingApproval> approvals;
  final List<DshPendingQuestion> questions;

  /// `contextPressure`: the composer ring's numerator/window; null hides it.
  final DshContextPressure? contextPressure;

  /// `imageLimits`: the composer's inline-image budget; null when unreported.
  final DshImageLimits? imageLimits;

  /// `commands/list`: every user-invocable slash command the Host advertises.
  final List<DshSlashCommand> commands;

  /// The catalog model behind [modelSelection]/the catalog default.
  DshModelOption? get currentModel => modelCatalog.modelFor(modelSelection);

  /// The effort the composer's reasoning control should display.
  DshReasoningEffort? get currentReasoningEffort {
    final model = currentModel;
    if (model == null) return null;
    return model.resolveEffort(modelSelection?.reasoningEffortId);
  }

  /// True while the composer must show the stop affordance.
  bool get busy => running || isSending;

  /// App-bar subtitle: `model (provider)`, e.g. `deepseek-flash (DeepSeek)`.
  ///
  /// Empty when the catalog has not loaded yet; the app bar then shows only the
  /// title instead of inventing a model name.
  String get modelDisplay {
    final model = currentModel;
    if (model == null) return '';
    final group = modelCatalog.groupFor(modelSelection);
    final providerName = group?.displayName.trim() ?? '';
    return providerName.isEmpty
        ? model.displayName
        : '${model.displayName} ($providerName)';
  }

  /// Alias the app bar reads; same value as [running].
  bool get isRunning => running;

  /// Alias the app bar reads; same value as [queuedPromptCount].
  int get queueCount => queuedPromptCount;

  /// The current permission preset's display name, when the Host composes the
  /// permission service. Unknown raw values (`auto`, `custom`) pass through.
  String? get permissionPreset {
    final permissions = this.permissions;
    if (permissions == null) return null;
    final current = permissions.currentOption;
    if (current != null) return current.name;
    final raw = permissions.currentValue.trim();
    return raw.isEmpty ? null : raw;
  }

  DshChatViewState copyWith({
    List<DshChatItem>? items,
    String? title,
    String? workspaceLabel,
    bool? running,
    bool? isSending,
    int? queuedPromptCount,
    bool? stale,
    String? connectionError,
    DshConnectionProblem? connectionProblem,
    DshModelSelection? modelSelection,
    DshModelCatalog? modelCatalog,
    DshPermissionState? permissions,
    DshAgentPresetState? agentPresets,
    DshContextPressure? contextPressure,
    DshImageLimits? imageLimits,
    List<DshSlashCommand>? commands,
    List<DshPendingApproval>? approvals,
    List<DshPendingQuestion>? questions,
  }) {
    return DshChatViewState(
      items: items ?? this.items,
      title: title ?? this.title,
      workspaceLabel: workspaceLabel ?? this.workspaceLabel,
      running: running ?? this.running,
      isSending: isSending ?? this.isSending,
      queuedPromptCount: queuedPromptCount ?? this.queuedPromptCount,
      stale: stale ?? this.stale,
      connectionError: connectionError ?? this.connectionError,
      connectionProblem: connectionProblem ?? this.connectionProblem,
      modelSelection: modelSelection ?? this.modelSelection,
      modelCatalog: modelCatalog ?? this.modelCatalog,
      permissions: permissions ?? this.permissions,
      agentPresets: agentPresets ?? this.agentPresets,
      contextPressure: contextPressure ?? this.contextPressure,
      imageLimits: imageLimits ?? this.imageLimits,
      commands: commands ?? this.commands,
      approvals: approvals ?? this.approvals,
      questions: questions ?? this.questions,
    );
  }
}

/// Outcome of submitting a prompt to the Host.
enum DshPromptSendStatus { accepted, rejected }

@immutable
class DshPromptSendResult {
  const DshPromptSendResult._(this.status, this.message);

  const DshPromptSendResult.accepted()
    : this._(DshPromptSendStatus.accepted, null);

  const DshPromptSendResult.rejected(String? message)
    : this._(DshPromptSendStatus.rejected, message);

  final DshPromptSendStatus status;

  /// Host-supplied rejection text (already user-readable), when any.
  final String? message;

  bool get isAccepted => status == DshPromptSendStatus.accepted;
}

/// One open remote session, as the chat surface sees it.
///
/// The stage-2 controller implements this over `lib/core/dsh`; stage 1 renders
/// against it with fakes. Every mutation is asynchronous because the Host owns
/// the state: a method's future completes when the server accepted (or
/// refused) the intent, never optimistically.
abstract class DshChatSession extends ChangeNotifier {
  /// The latest frame; implementations notify listeners when it changes.
  DshChatViewState get state;

  /// Whether this session may prompt remotely (link ready).
  bool get canSend;

  /// Submits one prompt. Only an accepted result may clear the composer.
  Future<DshPromptSendResult> sendPrompt(
    String text, {
    List<DshPromptAttachment> attachments = const <DshPromptAttachment>[],
  });

  /// Uploads one document's bytes and returns the receipt id for its prompt
  /// part.
  ///
  /// The composer's attachment service uses this for non-image files; images
  /// travel inline and never hit the upload endpoint. The upload route only
  /// takes the plain-file branch when no media type is declared.
  Future<String> uploadAttachment(List<int> bytes, {String? name});

  /// Executes one slash-command line through the Host's command path.
  ///
  /// The composer's slash list and the plus menu's compress row use this; a
  /// refusal is returned as [DshCommandResult.success] false, not thrown as a
  /// link failure.
  Future<DshCommandResult> runCommand(String line);

  /// Requests cancellation of the running turn.
  Future<void> cancelTurn();

  /// Switches provider/model/effort for this session in one write.
  Future<DshModelSelection?> selectModel(DshModelSelection selection);

  /// Re-reads the model catalog (retry after a failed load).
  Future<void> refreshModelCatalog();

  /// Changes the session's permission preset. Stage 2 routes this through the
  /// `/permission` command (there is no dedicated set-permission RPC).
  Future<void> setPermission(String value);

  /// Records the Agent preset for the open Session.
  ///
  /// Only valid before the Session's first turn: the Host refuses with
  /// `agent-preset/locked` afterwards and the refusal surfaces through
  /// [DshGatewayException.detail].
  Future<void> selectAgentPreset(String presetId);

  /// Answers a pending approval waterfall; the turn blocks until it is.
  Future<void> answerApproval(String requestId, {required bool allow});

  /// Answers a pending user-questions waterfall.
  Future<void> answerQuestions(
    String requestId,
    List<DshQuestionAnswer> answers,
  );

  /// Declines a pending user-questions waterfall.
  Future<void> rejectQuestions(String requestId);

  /// Reloads the session after a link failure.
  Future<void> reload();
}
