import 'dart:convert';

import '../api/chat_api_service.dart';
import '../../providers/model_provider.dart';
import '../../providers/settings_provider.dart';

/// Outcome of one director tool call (select speaker or end round).
class DirectorDecision {
  const DirectorDecision.selectSpeaker({required this.assistantId, this.reason})
    : endRound = false;

  const DirectorDecision.endRound({this.reason})
    : endRound = true,
      assistantId = null;

  final bool endRound;
  final String? assistantId;
  final String? reason;

  bool get isSelectSpeaker => !endRound && (assistantId?.isNotEmpty ?? false);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'endRound': endRound,
    'assistantId': assistantId,
    'reason': reason,
  };
}

/// Director tool names and OpenAI-style tool definitions.
class DirectorToolService {
  static const String toolSelectSpeaker = 'select_speaker';
  static const String toolEndRound = 'end_round';

  DirectorDecision? lastDecision;
  final List<DirectorDecision> decisions = <DirectorDecision>[];

  bool get hasDecision => lastDecision != null;

  void reset() {
    lastDecision = null;
    decisions.clear();
  }

  /// Tool schemas for [ChatApiService.sendMessageStream].
  static List<Map<String, dynamic>> toolDefinitions({
    List<String>? allowedAssistantIds,
  }) {
    final idDesc = allowedAssistantIds == null || allowedAssistantIds.isEmpty
        ? '成员助手的 assistant_id（必须来自成员列表）'
        : '成员助手的 assistant_id，必须是以下之一: ${allowedAssistantIds.join(', ')}';

    return <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'function',
        'function': <String, dynamic>{
          'name': toolSelectSpeaker,
          'description': '选择下一位对用户可见发言的成员助手。调用后立即停止；不要撰写对用户的回复正文。',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'assistant_id': <String, dynamic>{
                'type': 'string',
                'description': idDesc,
              },
              'reason': <String, dynamic>{
                'type': 'string',
                'description': '简短理由（可选，不对用户展示）',
              },
            },
            'required': <String>['assistant_id'],
          },
        },
      },
      <String, dynamic>{
        'type': 'function',
        'function': <String, dynamic>{
          'name': toolEndRound,
          'description': '结束本轮（用户本条消息后的助手发言轮次）。话题已充分回应时调用。',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'reason': <String, dynamic>{
                'type': 'string',
                'description': '简短理由（可选，不对用户展示）',
              },
            },
          },
        },
      },
    ];
  }

  /// Parse a tool call into a [DirectorDecision], or null if unrecognized.
  static DirectorDecision? parseToolCall(
    String name,
    Map<String, dynamic> args,
  ) {
    final n = name.trim();
    if (n == toolEndRound) {
      final reason = args['reason']?.toString();
      return DirectorDecision.endRound(
        reason: (reason == null || reason.trim().isEmpty)
            ? null
            : reason.trim(),
      );
    }
    if (n == toolSelectSpeaker) {
      final id = (args['assistant_id'] ?? args['assistantId'] ?? '')
          .toString()
          .trim();
      if (id.isEmpty) return null;
      final reason = args['reason']?.toString();
      return DirectorDecision.selectSpeaker(
        assistantId: id,
        reason: (reason == null || reason.trim().isEmpty)
            ? null
            : reason.trim(),
      );
    }
    return null;
  }

  /// Handler that records the first valid decision and optionally cancels the
  /// in-flight director request so the provider does not follow up with body text.
  ToolCallHandler buildHandler({
    String? requestId,
    Set<String>? allowedAssistantIds,
    void Function(DirectorDecision decision)? onDecided,
  }) {
    return (
      String name,
      Map<String, dynamic> args, {
      String? toolCallId,
    }) async {
      // Already decided — select-speaker stops further director work.
      if (lastDecision != null) {
        return jsonEncode(<String, dynamic>{
          'ok': true,
          'ignored': true,
          'message': 'decision already taken',
        });
      }

      final parsed = parseToolCall(name, args);
      if (parsed == null) {
        return jsonEncode(<String, dynamic>{
          'ok': false,
          'error': 'unknown_or_invalid_tool',
          'name': name,
        });
      }

      if (parsed.isSelectSpeaker &&
          allowedAssistantIds != null &&
          allowedAssistantIds.isNotEmpty &&
          !allowedAssistantIds.contains(parsed.assistantId)) {
        return jsonEncode(<String, dynamic>{
          'ok': false,
          'error': 'assistant_not_in_group',
          'assistant_id': parsed.assistantId,
        });
      }

      lastDecision = parsed;
      decisions.add(parsed);
      onDecided?.call(parsed);

      final rid = (requestId ?? '').trim();
      if (rid.isNotEmpty) {
        // Stop provider-internal tool follow-up so the director never drafts body text.
        Future.microtask(() {
          try {
            ChatApiService.cancelRequest(rid);
          } catch (_) {}
        });
      }

      return jsonEncode(<String, dynamic>{
        'ok': true,
        'decision': parsed.toJson(),
      });
    };
  }
}

/// Whether a model supports tool calling (director requirement — no JSON fallback).
///
/// Mirrors [GenerationController.isToolModel] without needing a BuildContext.
bool modelSupportsToolCalling({
  required ProviderConfig config,
  required String modelId,
}) {
  final mid = modelId.trim();
  if (mid.isEmpty) return false;
  final ov = config.modelOverrides[mid];
  if (ov is Map && ov.containsKey('abilities')) {
    final abilities =
        (ov['abilities'] as List?)
            ?.map((e) => e.toString().toLowerCase())
            .where((e) => e.isNotEmpty)
            .toList() ??
        const <String>[];
    return abilities.contains('tool');
  }
  final inferred = ModelRegistry.infer(ModelInfo(id: mid, displayName: mid));
  return inferred.abilities.contains(ModelAbility.tool);
}

/// Resolve director provider/model from group settings with global fallback.
({String? providerKey, String? modelId}) resolveDirectorModel({
  required GroupChatSettingsLike settings,
  String? groupDirectorProvider,
  String? groupDirectorModelId,
}) {
  final p = (groupDirectorProvider ?? settings.currentModelProvider)?.trim();
  final m = (groupDirectorModelId ?? settings.currentModelId)?.trim();
  return (
    providerKey: (p == null || p.isEmpty) ? null : p,
    modelId: (m == null || m.isEmpty) ? null : m,
  );
}

/// Minimal surface used by [resolveDirectorModel] so tests need not construct
/// a full [SettingsProvider].
abstract class GroupChatSettingsLike {
  String? get currentModelProvider;
  String? get currentModelId;
}

/// Adapter for live [SettingsProvider].
class SettingsProviderAdapter implements GroupChatSettingsLike {
  SettingsProviderAdapter(this._settings);
  final SettingsProvider _settings;

  @override
  String? get currentModelProvider => _settings.currentModelProvider;

  @override
  String? get currentModelId => _settings.currentModelId;
}
