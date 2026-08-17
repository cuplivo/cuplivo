import 'dart:convert';

import 'package:crypto/crypto.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/providers/settings_provider.dart';
import '../utils/message_visual_content.dart';
import 'web_transcript_models.dart';

class WebTranscriptLabels {
  const WebTranscriptLabels({
    required this.user,
    required this.assistant,
    required this.resend,
    required this.regenerate,
    required this.translate,
    required this.speak,
    required this.edit,
    required this.more,
    required this.previousVersion,
    required this.nextVersion,
    required this.reasoning,
    required this.toolCall,
    required this.arguments,
    required this.result,
    required this.noResult,
    required this.translation,
  });

  final String user;
  final String assistant;
  final String resend;
  final String regenerate;
  final String translate;
  final String speak;
  final String edit;
  final String more;
  final String previousVersion;
  final String nextVersion;
  final String reasoning;
  final String toolCall;
  final String arguments;
  final String result;
  final String noResult;
  final String translation;
}

class WebTranscriptReasoning {
  const WebTranscriptReasoning({
    required this.text,
    required this.expanded,
    required this.loading,
    this.toolStartIndex = 0,
  });

  final String text;
  final bool expanded;
  final bool loading;
  final int toolStartIndex;
}

class WebTranscriptTool {
  const WebTranscriptTool({
    required this.name,
    required this.arguments,
    required this.content,
    required this.loading,
  });

  final String name;
  final Map<String, dynamic> arguments;
  final String? content;
  final bool loading;
}

class WebTranscriptSplits {
  const WebTranscriptSplits({
    required this.offsets,
    required this.reasoningCounts,
    required this.toolCounts,
  });

  final List<int> offsets;
  final List<int> reasoningCounts;
  final List<int> toolCounts;
}

class WebTranscriptProjection {
  const WebTranscriptProjection._();

  static WebTranscriptSnapshot build({
    required String conversationId,
    required List<ChatMessage> messages,
    required SettingsProvider settings,
    required WebTranscriptLabels labels,
    required Assistant? Function(ChatMessage message) resolveAssistant,
    required Map<String, List<ChatMessage>> byGroup,
    required Map<String, int> versionSelections,
    required Map<String, List<WebTranscriptReasoning>> reasoning,
    required Map<String, List<WebTranscriptTool>> tools,
    required Map<String, WebTranscriptSplits> splits,
    required String Function(ChatMessage message) formatTimestamp,
    required Set<String> selectedItems,
    required Set<String> collapsedTranslations,
    required bool selecting,
    required bool hasMoreBefore,
    required bool hasMoreAfter,
    List<String> suggestions = const <String>[],
    String? spotlightMessageId,
  }) {
    final resources = <String, WebTranscriptResource>{};
    final projected = <WebTranscriptMessage>[];
    for (final message in messages) {
      projected.add(
        _projectMessage(
          message: message,
          settings: settings,
          labels: labels,
          assistant: resolveAssistant(message),
          byGroup: byGroup,
          versionSelections: versionSelections,
          reasoning: reasoning[message.id] ?? const <WebTranscriptReasoning>[],
          tools: tools[message.id] ?? const <WebTranscriptTool>[],
          splits: splits[message.id],
          formattedTimestamp: formatTimestamp(message),
          resources: resources,
          selected: selectedItems.contains(message.id),
          selecting: selecting,
          suggestions:
              !selecting &&
                  message.role == 'assistant' &&
                  !message.isStreaming &&
                  message.id == messages.lastOrNull?.id
              ? suggestions
              : const [],
          spotlight: message.id == spotlightMessageId,
          translationCollapsed: collapsedTranslations.contains(message.id),
        ),
      );
    }
    return WebTranscriptSnapshot(
      conversationId: conversationId,
      messages: projected,
      resources: resources,
      hasMoreBefore: hasMoreBefore,
      hasMoreAfter: hasMoreAfter,
    );
  }

  static WebTranscriptMessage _projectMessage({
    required ChatMessage message,
    required SettingsProvider settings,
    required WebTranscriptLabels labels,
    required Assistant? assistant,
    required Map<String, List<ChatMessage>> byGroup,
    required Map<String, int> versionSelections,
    required List<WebTranscriptReasoning> reasoning,
    required List<WebTranscriptTool> tools,
    required WebTranscriptSplits? splits,
    required String formattedTimestamp,
    required Map<String, WebTranscriptResource> resources,
    required bool selected,
    required bool selecting,
    required List<String> suggestions,
    required bool spotlight,
    required bool translationCollapsed,
  }) {
    final markdownEnabled = message.role == 'user'
        ? settings.enableUserMarkdown
        : settings.enableAssistantMarkdown;
    var content = message.role == 'assistant'
        ? messageVisualContent(message, assistant: assistant)
        : message.content;
    content = _replaceResources(message.id, content, resources);
    if (!markdownEnabled) {
      content = _escapeMarkdownPreservingResources(content);
    }
    if (message.role == 'assistant') {
      content = _composeAssistantContent(
        content: content,
        reasoning: reasoning,
        tools: tools,
        splits: splits,
        labels: labels,
        reasoningMarkdown: settings.enableReasoningMarkdown,
      );
      if (message.translation?.trim().isNotEmpty == true &&
          !translationCollapsed) {
        var translation = _replaceResources(
          message.id,
          message.translation!,
          resources,
          scope: 'translation',
        );
        if (!markdownEnabled) {
          translation = _escapeMarkdownPreservingResources(translation);
        }
        content =
            '$content\n\n---\n\n### ${labels.translation}\n\n'
            '$translation';
      }
    }

    final groupId = message.groupId ?? message.id;
    final versions = byGroup[groupId] ?? const <ChatMessage>[];
    final selectedVersion = versionSelections[groupId] ?? message.version;
    final actions = <WebTranscriptAction>[];
    if (selecting) {
      actions.add(
        WebTranscriptAction(selected ? 'unselect' : 'select', labels.more),
      );
    } else if (message.role == 'user') {
      if (settings.showUserMessageActions) {
        actions.add(WebTranscriptAction('resend', labels.resend));
        actions.add(WebTranscriptAction('edit', labels.edit));
        actions.add(WebTranscriptAction('more', labels.more));
      }
    } else if (!message.isStreaming) {
      actions.add(WebTranscriptAction('regenerate', labels.regenerate));
      actions.add(WebTranscriptAction('translate', labels.translate));
      actions.add(WebTranscriptAction('speak', labels.speak));
      actions.add(WebTranscriptAction('more', labels.more));
    }
    if (versions.length > 1 && selectedVersion > 0) {
      actions.insert(
        0,
        WebTranscriptAction('previousVersion', labels.previousVersion),
      );
    }
    if (versions.length > 1 && selectedVersion < versions.length - 1) {
      actions.insert(0, WebTranscriptAction('nextVersion', labels.nextVersion));
    }
    if (reasoning.isNotEmpty) {
      actions.add(WebTranscriptAction('toggleReasoning', labels.reasoning));
    }
    if (message.translation?.trim().isNotEmpty == true) {
      actions.add(WebTranscriptAction('toggleTranslation', labels.translation));
    }
    for (final suggestion in suggestions) {
      actions.add(
        WebTranscriptAction('suggestion', suggestion, value: suggestion),
      );
    }

    return WebTranscriptMessage(
      source: message,
      markdown: content,
      format: 'markdown',
      displayName: message.role == 'user'
          ? (settings.showUserName ? labels.user : '')
          : (settings.showModelName
                ? (assistant?.name.trim().isNotEmpty == true
                      ? assistant!.name.trim()
                      : labels.assistant)
                : ''),
      timestamp: message.role == 'user'
          ? (settings.showUserTimestamp ? formattedTimestamp : '')
          : (settings.showModelTimestamp ? formattedTimestamp : ''),
      timestampIso: message.timestamp.toIso8601String(),
      actions: actions,
      selected: selected,
      spotlight: spotlight,
    );
  }

  static String _composeAssistantContent({
    required String content,
    required List<WebTranscriptReasoning> reasoning,
    required List<WebTranscriptTool> tools,
    required WebTranscriptSplits? splits,
    required WebTranscriptLabels labels,
    required bool reasoningMarkdown,
  }) {
    final visibleTools = tools.where((tool) => tool.name != 'builtin_search');
    final steps = <_TimelineStep>[];
    var reasoningCount = 0;
    var toolCount = 0;
    var toolIndex = 0;
    final toolList = visibleTools.toList();
    for (var i = 0; i < reasoning.length; i++) {
      final segment = reasoning[i];
      final start = segment.toolStartIndex.clamp(0, toolList.length);
      while (toolIndex < start) {
        steps.add(
          _TimelineStep.tool(toolList[toolIndex], reasoningCount, ++toolCount),
        );
        toolIndex++;
      }
      if (segment.text.isNotEmpty) {
        steps.add(
          _TimelineStep.reasoning(segment, ++reasoningCount, toolCount),
        );
      }
      final end = i < reasoning.length - 1
          ? reasoning[i + 1].toolStartIndex.clamp(0, toolList.length)
          : toolList.length;
      while (toolIndex < end) {
        steps.add(
          _TimelineStep.tool(toolList[toolIndex], reasoningCount, ++toolCount),
        );
        toolIndex++;
      }
    }
    while (toolIndex < toolList.length) {
      steps.add(
        _TimelineStep.tool(toolList[toolIndex], reasoningCount, ++toolCount),
      );
      toolIndex++;
    }
    if (steps.isEmpty) return content;

    String renderSteps(List<_TimelineStep> items) => items
        .map(
          (step) => step.reasoning != null
              ? _reasoningMarkdown(step.reasoning!, labels, reasoningMarkdown)
              : _toolMarkdown(step.tool!, labels),
        )
        .join('\n\n');

    if (splits == null || splits.offsets.isEmpty) {
      return '${renderSteps(steps)}\n\n$content'.trim();
    }

    final blocks = <String>[];
    var stepIndex = 0;
    var textStart = 0;
    for (var i = 0; i < splits.offsets.length; i++) {
      final offset = splits.offsets[i].clamp(0, content.length);
      final text = content.substring(textStart, offset).trim();
      if (text.isNotEmpty) blocks.add(text);
      final targetReasoning = i < splits.reasoningCounts.length
          ? splits.reasoningCounts[i]
          : 0;
      final targetTool = i < splits.toolCounts.length
          ? splits.toolCounts[i]
          : 0;
      final current = <_TimelineStep>[];
      while (stepIndex < steps.length) {
        final step = steps[stepIndex++];
        current.add(step);
        if (step.reasoningCount == targetReasoning &&
            step.toolCount == targetTool) {
          break;
        }
      }
      if (current.isNotEmpty) blocks.add(renderSteps(current));
      textStart = offset;
    }
    final trailing = content.substring(textStart).trim();
    if (trailing.isNotEmpty) blocks.add(trailing);
    if (stepIndex < steps.length) {
      blocks.add(renderSteps(steps.sublist(stepIndex)));
    }
    return blocks.join('\n\n').trim();
  }

  static String _reasoningMarkdown(
    WebTranscriptReasoning reasoning,
    WebTranscriptLabels labels,
    bool markdownEnabled,
  ) {
    final status = reasoning.loading ? '...' : '';
    if (!reasoning.expanded) return '> **${labels.reasoning}$status**';
    final body = markdownEnabled
        ? reasoning.text
        : _escapeMarkdown(reasoning.text);
    return '> **${labels.reasoning}$status**\n>\n> '
        '${body.replaceAll('\n', '\n> ')}';
  }

  static String _toolMarkdown(
    WebTranscriptTool tool,
    WebTranscriptLabels labels,
  ) {
    final arguments = const JsonEncoder.withIndent(
      '  ',
    ).convert(tool.arguments);
    final result = tool.content?.trim().isNotEmpty == true
        ? tool.content!.trim()
        : labels.noResult;
    return '> **${labels.toolCall.replaceAll('{name}', tool.name)}**\n>\n'
        '> ${labels.arguments}\n> ```json\n> ${arguments.replaceAll('\n', '\n> ')}\n> ```\n>\n'
        '> ${labels.result}${tool.loading ? '...' : ''}\n> '
        '${result.replaceAll('\n', '\n> ')}';
  }

  static String _replaceResources(
    String messageId,
    String source,
    Map<String, WebTranscriptResource> resources, {
    String scope = 'content',
  }) {
    var imageIndex = 0;
    var fileIndex = 0;
    var result = source.replaceAllMapped(RegExp(r'\[image:(.+?)\]'), (match) {
      final path = match.group(1)!.trim();
      final id = _resourceId(messageId, scope, 'image', imageIndex++, path);
      resources[id] = WebTranscriptResource(
        id: id,
        source: path,
        kind: WebTranscriptResourceKind.image,
      );
      return '![image](cuplivo-resource://$id)';
    });
    result = result.replaceAllMapped(RegExp(r'\[file:(.+?)\|(.+?)\|(.+?)\]'), (
      match,
    ) {
      final path = match.group(1)!.trim();
      final name = match.group(2)!.trim();
      final mime = match.group(3)!.trim();
      final id = _resourceId(messageId, scope, 'file', fileIndex++, path);
      resources[id] = WebTranscriptResource(
        id: id,
        source: path,
        kind: WebTranscriptResourceKind.attachment,
        fileName: name,
        mimeType: mime,
      );
      return '[$name](cuplivo-resource://$id)';
    });
    result = result.replaceAllMapped(
      RegExp(r'!\[([^\]]*)\]\((https://[^\s)]+)\)'),
      (match) {
        final remote = match.group(2)!;
        final id = _resourceId(
          messageId,
          scope,
          'remote-image',
          imageIndex++,
          remote,
        );
        resources[id] = WebTranscriptResource(
          id: id,
          source: remote,
          kind: WebTranscriptResourceKind.image,
        );
        return '![${match.group(1) ?? 'image'}](cuplivo-resource://$id)';
      },
    );
    return result;
  }

  static String _resourceId(
    String messageId,
    String scope,
    String kind,
    int index,
    String source,
  ) {
    final digest = sha256
        .convert(utf8.encode(source))
        .toString()
        .substring(0, 12);
    return '$messageId:$scope:$kind:$index:$digest';
  }

  static String _escapeMarkdownPreservingResources(String source) {
    final resourcePattern = RegExp(r'!?\[[^\]]*\]\(cuplivo-resource://[^)]+\)');
    final buffer = StringBuffer();
    var offset = 0;
    for (final match in resourcePattern.allMatches(source)) {
      buffer.write(_escapeMarkdown(source.substring(offset, match.start)));
      buffer.write(match.group(0));
      offset = match.end;
    }
    buffer.write(_escapeMarkdown(source.substring(offset)));
    return buffer.toString();
  }

  static String _escapeMarkdown(String value) {
    return value.replaceAllMapped(
      RegExp(r'([\\`*_{}\[\]()#+\-.!|>])'),
      (match) => '\\${match.group(1)}',
    );
  }
}

class _TimelineStep {
  const _TimelineStep._({
    required this.reasoning,
    required this.tool,
    required this.reasoningCount,
    required this.toolCount,
  });

  factory _TimelineStep.reasoning(
    WebTranscriptReasoning reasoning,
    int reasoningCount,
    int toolCount,
  ) => _TimelineStep._(
    reasoning: reasoning,
    tool: null,
    reasoningCount: reasoningCount,
    toolCount: toolCount,
  );

  factory _TimelineStep.tool(
    WebTranscriptTool tool,
    int reasoningCount,
    int toolCount,
  ) => _TimelineStep._(
    reasoning: null,
    tool: tool,
    reasoningCount: reasoningCount,
    toolCount: toolCount,
  );

  final WebTranscriptReasoning? reasoning;
  final WebTranscriptTool? tool;
  final int reasoningCount;
  final int toolCount;
}
