import 'dart:convert';

import 'package:flutter/foundation.dart';

enum QuickInstructionPlacement {
  systemPrompt,
  beforeUserMessage,
  afterUserMessage,
  inputBox;

  static QuickInstructionPlacement fromJson(Object? value) {
    return QuickInstructionPlacement.values.firstWhere(
      (item) => item.name == value,
      orElse: () => QuickInstructionPlacement.systemPrompt,
    );
  }
}

enum QuickInstructionTriggerMode {
  oneShot,
  persistent;

  static QuickInstructionTriggerMode fromJson(Object? value) {
    return QuickInstructionTriggerMode.values.firstWhere(
      (item) => item.name == value,
      orElse: () => QuickInstructionTriggerMode.oneShot,
    );
  }
}

class QuickInstructionToolPolicy {
  QuickInstructionToolPolicy({
    this.enabled = false,
    List<String> disabledLocalToolIds = const <String>[],
    List<String> disabledMcpServerIds = const <String>[],
    List<String> disabledFilesystemToolNames = const <String>[],
    this.shellDisabled = false,
    List<String> shellBlockPatterns = const <String>[],
  }) : disabledLocalToolIds = List<String>.unmodifiable(disabledLocalToolIds),
       disabledMcpServerIds = List<String>.unmodifiable(disabledMcpServerIds),
       disabledFilesystemToolNames = List<String>.unmodifiable(
         disabledFilesystemToolNames,
       ),
       shellBlockPatterns = List<String>.unmodifiable(shellBlockPatterns);

  final bool enabled;
  final List<String> disabledLocalToolIds;
  final List<String> disabledMcpServerIds;
  final List<String> disabledFilesystemToolNames;
  final bool shellDisabled;
  final List<String> shellBlockPatterns;

  static List<String> _strings(Object? value) {
    if (value is! List) return const <String>[];
    return List<String>.unmodifiable(
      value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toSet(),
    );
  }

  QuickInstructionToolPolicy copyWith({
    bool? enabled,
    List<String>? disabledLocalToolIds,
    List<String>? disabledMcpServerIds,
    List<String>? disabledFilesystemToolNames,
    bool? shellDisabled,
    List<String>? shellBlockPatterns,
  }) {
    return QuickInstructionToolPolicy(
      enabled: enabled ?? this.enabled,
      disabledLocalToolIds: disabledLocalToolIds ?? this.disabledLocalToolIds,
      disabledMcpServerIds: disabledMcpServerIds ?? this.disabledMcpServerIds,
      disabledFilesystemToolNames:
          disabledFilesystemToolNames ?? this.disabledFilesystemToolNames,
      shellDisabled: shellDisabled ?? this.shellDisabled,
      shellBlockPatterns: shellBlockPatterns ?? this.shellBlockPatterns,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'enabled': enabled,
    'disabledLocalToolIds': disabledLocalToolIds,
    'disabledMcpServerIds': disabledMcpServerIds,
    'disabledFilesystemToolNames': disabledFilesystemToolNames,
    'shellDisabled': shellDisabled,
    'shellBlockPatterns': shellBlockPatterns,
  };

  factory QuickInstructionToolPolicy.fromJson(Object? value) {
    if (value is! Map) return QuickInstructionToolPolicy();
    final json = value.cast<String, dynamic>();
    return QuickInstructionToolPolicy(
      enabled: json['enabled'] as bool? ?? false,
      disabledLocalToolIds: _strings(json['disabledLocalToolIds']),
      disabledMcpServerIds: _strings(json['disabledMcpServerIds']),
      disabledFilesystemToolNames: _strings(
        json['disabledFilesystemToolNames'],
      ),
      shellDisabled: json['shellDisabled'] as bool? ?? false,
      shellBlockPatterns: _strings(json['shellBlockPatterns']),
    );
  }
}

class QuickInstruction {
  QuickInstruction({
    required this.id,
    required this.title,
    required this.prompt,
    this.group = '',
    this.placement = QuickInstructionPlacement.beforeUserMessage,
    this.triggerMode = QuickInstructionTriggerMode.oneShot,
    this.retainInHistory = true,
    QuickInstructionToolPolicy? toolPolicy,
  }) : toolPolicy = toolPolicy ?? QuickInstructionToolPolicy();

  final String id;
  final String title;
  final String prompt;
  final String group;
  final QuickInstructionPlacement placement;
  final QuickInstructionTriggerMode triggerMode;
  final bool retainInHistory;
  final QuickInstructionToolPolicy toolPolicy;

  bool get isSystem => placement == QuickInstructionPlacement.systemPrompt;
  bool get isUserMessage =>
      placement == QuickInstructionPlacement.beforeUserMessage ||
      placement == QuickInstructionPlacement.afterUserMessage;
  bool get isInputBox => placement == QuickInstructionPlacement.inputBox;
  bool get isPersistent =>
      isUserMessage && triggerMode == QuickInstructionTriggerMode.persistent;
  bool get isOneShot =>
      isUserMessage && triggerMode == QuickInstructionTriggerMode.oneShot;

  QuickInstruction copyWith({
    String? id,
    String? title,
    String? prompt,
    String? group,
    QuickInstructionPlacement? placement,
    QuickInstructionTriggerMode? triggerMode,
    bool? retainInHistory,
    QuickInstructionToolPolicy? toolPolicy,
  }) {
    return QuickInstruction(
      id: id ?? this.id,
      title: title ?? this.title,
      prompt: prompt ?? this.prompt,
      group: group ?? this.group,
      placement: placement ?? this.placement,
      triggerMode: triggerMode ?? this.triggerMode,
      retainInHistory: retainInHistory ?? this.retainInHistory,
      toolPolicy: toolPolicy ?? this.toolPolicy,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'prompt': prompt,
    'group': group,
    'placement': placement.name,
    'triggerMode': triggerMode.name,
    'retainInHistory': retainInHistory,
    'toolPolicy': toolPolicy.toJson(),
  };

  static QuickInstruction fromJson(Map<String, dynamic> json) {
    return QuickInstruction(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      prompt: json['prompt']?.toString() ?? '',
      group: json['group']?.toString() ?? '',
      placement: QuickInstructionPlacement.fromJson(json['placement']),
      triggerMode: QuickInstructionTriggerMode.fromJson(json['triggerMode']),
      retainInHistory: json['retainInHistory'] as bool? ?? true,
      toolPolicy: QuickInstructionToolPolicy.fromJson(json['toolPolicy']),
    );
  }
}

class QuickInstructionInvocationSnapshot {
  QuickInstructionInvocationSnapshot({
    required this.instructionId,
    required this.title,
    required this.prompt,
    required this.placement,
    required this.triggerMode,
    required this.retainInHistory,
    required QuickInstructionToolPolicy toolPolicy,
    required this.order,
  }) : toolPolicy = QuickInstructionToolPolicy.fromJson(toolPolicy.toJson());

  final String instructionId;
  final String title;
  final String prompt;
  final QuickInstructionPlacement placement;
  final QuickInstructionTriggerMode triggerMode;
  final bool retainInHistory;
  final QuickInstructionToolPolicy toolPolicy;
  final int order;

  factory QuickInstructionInvocationSnapshot.fromInstruction(
    QuickInstruction instruction, {
    required int order,
  }) {
    return QuickInstructionInvocationSnapshot(
      instructionId: instruction.id,
      title: instruction.title,
      prompt: instruction.prompt,
      placement: instruction.placement,
      triggerMode: instruction.triggerMode,
      retainInHistory: instruction.retainInHistory,
      toolPolicy: instruction.toolPolicy,
      order: order,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'instructionId': instructionId,
    'title': title,
    'prompt': prompt,
    'placement': placement.name,
    'triggerMode': triggerMode.name,
    'retainInHistory': retainInHistory,
    'toolPolicy': toolPolicy.toJson(),
    'order': order,
  };

  static QuickInstructionInvocationSnapshot fromJson(
    Map<String, dynamic> json,
  ) {
    return QuickInstructionInvocationSnapshot(
      instructionId: json['instructionId']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      prompt: json['prompt']?.toString() ?? '',
      placement: QuickInstructionPlacement.fromJson(json['placement']),
      triggerMode: QuickInstructionTriggerMode.fromJson(json['triggerMode']),
      retainInHistory: json['retainInHistory'] as bool? ?? true,
      toolPolicy: QuickInstructionToolPolicy.fromJson(json['toolPolicy']),
      order: (json['order'] as num?)?.toInt() ?? 0,
    );
  }

  static String encodeList(
    Iterable<QuickInstructionInvocationSnapshot> snapshots,
  ) {
    return jsonEncode(
      snapshots.map((snapshot) => snapshot.toJson()).toList(growable: false),
    );
  }

  static List<QuickInstructionInvocationSnapshot> decodeList(Object? raw) {
    if (raw == null) return const <QuickInstructionInvocationSnapshot>[];
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! List) {
        return const <QuickInstructionInvocationSnapshot>[];
      }
      return decoded
          .whereType<Map>()
          .map(
            (item) => QuickInstructionInvocationSnapshot.fromJson(
              item.cast<String, dynamic>(),
            ),
          )
          .toList(growable: false);
    } catch (error, stackTrace) {
      debugPrint(
        'QuickInstructionInvocationSnapshot.decodeList failed: '
        '$error\n$stackTrace',
      );
      return const <QuickInstructionInvocationSnapshot>[];
    }
  }
}
