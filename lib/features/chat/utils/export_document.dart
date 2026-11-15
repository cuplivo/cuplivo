import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:markstream/markstream_core.dart'
    show MarkdownParser, toPlainText;

import '../../../core/models/context_operation.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/message_part.dart';
import '../../intelligent_ui/host/ui_source_map.dart' show UiMessageSource;
import '../../intelligent_ui/text/ui_message_text.dart' show UiMessageText;
import 'message_reasoning_source.dart' show messageHasProviderReasoning;
import '../../../utils/mcp_structured_image.dart';
import '../../../utils/sandbox_path_resolver.dart';
import 'thinking_tag_parser.dart';

/// One piece of a message, in the order the export writes it.
///
/// The text exports and the PDF export walk the same parts of the same message,
/// so what a message *contains* is decided once, here, and each format decides
/// how to lay it out. The thinking-tag slicing, the tool envelope decode and the
/// order of parts relative to each other used to be re-derived per format; a
/// format that walked `message.parts` itself would be a third copy of rules that
/// only ever change together.
sealed class ExportBlock {
  const ExportBlock();
}

/// Body prose, as markdown source.
final class ExportText extends ExportBlock {
  const ExportText(this.text);

  final String text;
}

/// A reasoning section's text.
final class ExportReasoning extends ExportBlock {
  const ExportReasoning(this.text);

  final String text;
}

/// One tool call: the name it ran under and what came back.
final class ExportToolCall extends ExportBlock {
  const ExportToolCall({required this.name, required this.content});

  final String name;
  final String content;
}

/// An attachment picture.
///
/// [bytes] are the picture's own bytes when the caller asked for them, so a
/// renderer that embeds the image does not read the file a second time; a
/// renderer that only names it passes no reader and gets null.
final class ExportImage extends ExportBlock {
  const ExportImage({required this.uri, this.bytes});

  final String uri;
  final Uint8List? bytes;
}

/// A context operation (a compression or a clear) recorded between messages.
final class ExportContextNode extends ExportBlock {
  const ExportContextNode(this.text);

  final String text;
}

/// An attachment that is not a picture.
final class ExportFile extends ExportBlock {
  const ExportFile({required this.name, required this.mime});

  final String name;
  final String mime;
}

/// Who a message came from, as a layout's own chrome needs to know it.
///
/// [ExportMessage.roleName] is what a reader is shown, which is a translated
/// label or a profile name; this is what the message *is*. A format that draws a
/// speaker header asks this rather than reading the name, because a name is a
/// label and a label is not a role — the PDF prints a user's message without a
/// timestamp and under a fixed label, and cannot decide that from `roleName`.
enum ExportSpeaker { user, assistant }

/// One message as the export writes it: who said it, when, what, and how its
/// citations are numbered.
final class ExportMessage {
  const ExportMessage({
    required this.time,
    required this.roleName,
    required this.speaker,
    required this.blocks,
    this.citationIndex = const <String, String>{},
  });

  final String time;
  final String roleName;
  final ExportSpeaker speaker;
  final List<ExportBlock> blocks;

  /// The number each citation id is shown as.
  ///
  /// A marker the message wrote as `[citation](id)` names a search result by id,
  /// and the number a reader sees is that result's place in this message's own
  /// results — data a format cannot derive from the text, so the caller that
  /// knows the message hands it in. A format that draws citations as text (the
  /// Markdown and plain-text exports) leaves it empty.
  final Map<String, String> citationIndex;
}

/// A whole conversation, ready for a format to lay out.
final class ExportDocument {
  const ExportDocument({required this.title, required this.messages});

  final String title;
  final List<ExportMessage> messages;
}

/// Builds the export document for [messages].
///
/// [roleNameOf] and [formatTime] come from the caller because naming a speaker
/// and formatting a date are the surface's business (they read the settings,
/// the user profile and the locale); everything else about what a message
/// contains is decided here. [citationIndexOf] is the same kind of fact: which
/// search result a citation id names is known to the surface that holds the
/// message's tool events, and a format that draws numbered citations passes it.
///
/// Pass [readImageBytes] to have attachment pictures resolved once during the
/// build — the markdown and PDF exports do, because they embed the bytes —
/// and leave it null for a format that only names the file.
Future<ExportDocument> buildExportDocument({
  required String title,
  required List<ChatMessage> messages,
  required String Function(ChatMessage message) roleNameOf,
  required String Function(DateTime time) formatTime,
  required bool includeThinking,
  required bool includeTools,
  Map<String, String> Function(ChatMessage message)? citationIndexOf,
  Future<Uint8List?> Function(String uri)? readImageBytes,
  Map<String, UiMessageText> uiTextByMessage = const <String, UiMessageText>{},
  bool markdown = true,
  List<ContextOperation> operations = const <ContextOperation>[],
  String Function(ContextOperation op, {required bool hidden})? contextLabelOf,
}) async {
  final exported = <ExportMessage>[];
  for (final message in messages) {
    exported.add(
      ExportMessage(
        time: formatTime(message.timestamp),
        roleName: roleNameOf(message),
        speaker: message.role == 'user'
            ? ExportSpeaker.user
            : ExportSpeaker.assistant,
        citationIndex:
            citationIndexOf?.call(message) ?? const <String, String>{},
        blocks: [
          ...await exportBlocksOf(
            message,
            includeThinking: includeThinking,
            includeTools: includeTools,
            readImageBytes: readImageBytes,
            uiText: uiTextByMessage[message.id],
            markdown: markdown,
          ),
          // A compression or clear that anchors to this message is part of what
          // the message says to a reader, so it is written where it happened.
          for (final op in operations)
            if (op.anchorGroupId == ContextHistory.group(message) &&
                contextLabelOf != null)
              ExportContextNode(
                contextLabelOf(op, hidden: _contextNodeHidden(op, operations)),
              ),
        ],
      ),
    );
  }
  return ExportDocument(title: title, messages: exported);
}

/// Whether a later, still-live clear covers [op]'s group, which is what makes an
/// older marker read as hidden rather than active.
bool _contextNodeHidden(
  ContextOperation op,
  List<ContextOperation> operations,
) {
  return operations
      .skipWhile((item) => item.id != op.id)
      .skip(1)
      .any(
        (item) =>
            !item.revoked &&
            !item.isCompression &&
            item.sourceGroups.contains(op.anchorGroupId),
      );
}

/// The blocks [message] exports, in the order they appear on screen.
///
/// A reasoning part that the caller asked for is emitted where it sits in the
/// part list; when the message carries none, the thinking a legacy `<think>`
/// tag holds is appended at the end, which is where the renderer puts its card.
Future<List<ExportBlock>> exportBlocksOf(
  ChatMessage message, {
  required bool includeThinking,
  required bool includeTools,
  Future<Uint8List?> Function(String uri)? readImageBytes,
  UiMessageText? uiText,
  bool markdown = true,
}) async {
  final blocks = <ExportBlock>[];
  var wroteReasoningPart = false;
  final stripThink =
      message.role == 'assistant' && !messageHasProviderReasoning(message);
  final joinedText = stripThink ? message.content : '';
  final thinkRanges = stripThink
      ? ThinkingTagParser.parseWithRanges(
          joinedText,
          protectedRanges: UiMessageSource.of(
            message.parts,
          ).protectedJoinedRanges,
        )
      : null;
  var textOffset = 0;

  for (final part in message.parts) {
    switch (part) {
      case TextPart(:final text):
        final start = textOffset;
        final end = textOffset + text.length;
        textOffset = end;
        // A `<think>` span can start in one text part and end in another, so
        // the hidden ranges come from the whole message and each part is
        // sliced against them rather than parsed on its own.
        String ordinary(int from, int to) {
          final visible =
              thinkRanges == null || thinkRanges.hiddenRanges.isEmpty
              ? message.content.substring(from, to)
              : ThinkingTagParser.visibleSlice(
                  joinedText,
                  start: from,
                  end: to,
                  hiddenRanges: thinkRanges.hiddenRanges,
                );
          // A generated-UI surface reads as markdown on screen; a plain-text
          // export still wants it as prose, so its fence is flattened.
          return !markdown && uiText?.hasUi == true
              ? toPlainText(const MarkdownParser().parse(visible))
              : visible;
        }

        final body = uiText?.hasUi == true
            ? uiText!.exportSlice(
                start,
                end,
                markdown: markdown,
                ordinary: ordinary,
              )
            : ordinary(start, end);
        if (body.isEmpty) continue;
        blocks.add(ExportText(body));
      case ImagePart(:final uri):
        final trimmed = uri.trim();
        if (trimmed.isEmpty) continue;
        blocks.add(
          ExportImage(uri: trimmed, bytes: await readImageBytes?.call(trimmed)),
        );
      case FilePart(:final name, :final mime):
        blocks.add(
          ExportFile(name: name, mime: mime ?? 'application/octet-stream'),
        );
      case ReasoningPart(:final text):
        if (!includeThinking || text.trim().isEmpty) continue;
        wroteReasoningPart = true;
        blocks.add(ExportReasoning(text.trim()));
      case ToolCallPart(:final payloadJson):
        if (!includeTools) continue;
        try {
          final decoded = jsonDecode(payloadJson);
          if (decoded is! Map) continue;
          blocks.add(
            ExportToolCall(
              name: (decoded['name'] ?? '').toString(),
              content: toolResultContentForModel(
                decoded['content']?.toString(),
              ),
            ),
          );
        } catch (_) {}
      default:
        break;
    }
  }

  if (includeThinking && !wroteReasoningPart) {
    final thinkingTexts = thinkRanges != null && thinkRanges.hasThinking
        ? thinkRanges.thinkingTexts
        : thinkingExportDataForMessage(message).thinkingTexts;
    if (thinkingTexts.isNotEmpty) {
      final text = thinkingTexts.join('\n\n');
      if (text.isNotEmpty) blocks.add(ExportReasoning(text));
    }
  }

  return blocks;
}

/// Lays [blocks] out as text, in the shape the text exports share.
///
/// [imageLine] is the one thing the formats genuinely disagree about: markdown
/// embeds the picture's bytes (or names it when they could not be read), while
/// a plain-text export and the message-block test helper only write the URI.
String renderExportBlocks(
  List<ExportBlock> blocks, {
  required bool markdown,
  required String thinkingLabel,
  required String Function(ExportImage image) imageLine,
}) {
  final buf = StringBuffer();
  for (final block in blocks) {
    switch (block) {
      case ExportText(:final text):
        buf.writeln(text);
        buf.writeln('');
      case ExportImage():
        buf.writeln(imageLine(block));
        buf.writeln('');
      case ExportFile(:final name, :final mime):
        if (markdown) {
          buf.writeln('- $name  `($mime)`');
        } else {
          buf.writeln('- $name ($mime)');
        }
      case ExportContextNode(:final text):
        buf.writeln(markdown ? '### $text' : '[$text]');
        buf.writeln('');
      case ExportReasoning(:final text):
        buf.writeln('');
        buf.writeln(markdown ? '**$thinkingLabel**' : '[$thinkingLabel]');
        buf.writeln('');
        if (markdown) {
          buf.writeln('```text');
          buf.writeln(text);
          buf.writeln('```');
        } else {
          buf.writeln(text);
        }
        buf.writeln('');
      case ExportToolCall(:final name, :final content):
        buf.writeln(name.isEmpty ? '[tool]' : '[$name]');
        if (content.trim().isNotEmpty) {
          buf.writeln(content);
        }
        buf.writeln('');
    }
  }
  return buf.toString();
}

/// Lays the whole document out as text: a title, then one headed section per
/// message.
String renderExportDocument(
  ExportDocument document, {
  required bool markdown,
  required String thinkingLabel,
  required String Function(ExportImage image) imageLine,
}) {
  final buf = StringBuffer();
  buf.writeln(markdown ? '# ${document.title}' : document.title);
  buf.writeln('');
  for (final message in document.messages) {
    final header = '${message.time} · ${message.roleName}';
    buf.writeln(markdown ? '> $header' : header);
    buf.writeln('');
    buf.write(
      renderExportBlocks(
        message.blocks,
        markdown: markdown,
        thinkingLabel: thinkingLabel,
        imageLine: imageLine,
      ),
    );
    buf.writeln('\n---\n');
  }
  return buf.toString();
}

/// How a markdown export writes one attached picture: the bytes themselves as a
/// data URI, or the path when this device cannot read them.
String exportImageMarkdownLine(ExportImage image) {
  final fixed = SandboxPathResolver.fix(image.uri);
  final bytes = image.bytes;
  if (bytes == null) return '![image]($fixed)';
  return '![](data:${guessExportImageMime(fixed)};base64,${base64Encode(bytes)})';
}

/// Reads one attachment's bytes for a renderer that embeds the picture.
///
/// Answers null when the URI names nothing this device can read, which is what
/// makes every such renderer fall back to writing the URI, and is also what
/// keeps a distant or missing picture from failing the whole export.
Future<Uint8List?> readExportImageBytes(String uri) async {
  final fixed = SandboxPathResolver.fix(uri);
  try {
    final file = File(fixed);
    if (!await file.exists()) return null;
    return await file.readAsBytes();
  } catch (_) {
    return null;
  }
}

String guessExportImageMime(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'image/png';
}

class ThinkingExportData {
  const ThinkingExportData({
    required this.cleanedContent,
    required this.thinkingTexts,
    this.fromInlineThinking = false,
  });

  final String cleanedContent;
  final List<String> thinkingTexts;

  /// Whether [thinkingTexts] came from inline ` thinking` tags rather than from
  /// provider evidence, which is what decides whether segment timings have to
  /// be split along those tags.
  final bool fromInlineThinking;
}

/// The reasoning a message holds, however it recorded it.
///
/// Provider evidence wins: structured reasoning parts first, then the persisted
/// segments and the legacy `reasoningText` field. Only a message with no
/// provider reasoning falls back to inline `</think>` tags, because there the
/// tags *are* the only record of it.
ThinkingExportData thinkingExportDataForMessage(ChatMessage message) {
  final structuredReasoning = [
    for (final part in message.parts)
      if (part is ReasoningPart && part.text.trim().isNotEmpty)
        part.text.trim(),
  ];
  if (structuredReasoning.isNotEmpty) {
    return ThinkingExportData(
      cleanedContent: message.content.trim(),
      thinkingTexts: structuredReasoning,
    );
  }

  final providerReasoning = messageHasProviderReasoning(message);
  final thinkingTexts = <String>[];
  var cleanedContent = message.content.trim();
  var fromInlineThinking = false;

  final segJson = (message.reasoningSegmentsJson ?? '').trim();
  if (segJson.isNotEmpty && providerReasoning) {
    try {
      final decoded = jsonDecode(segJson);
      if (decoded is List) {
        _addReasoningSegmentTexts(thinkingTexts, decoded);
      } else if (decoded is Map) {
        _addReasoningSegmentTexts(
          thinkingTexts,
          decoded['segments'] as List? ?? const <dynamic>[],
        );
      }
    } catch (_) {}
  }

  if (thinkingTexts.isEmpty && providerReasoning) {
    final text = (message.reasoningText ?? '').trim();
    if (text.isNotEmpty) thinkingTexts.add(text);
  }
  if (!providerReasoning) {
    final parsed = ThinkingTagParser.parseWithRanges(
      message.content,
      protectedRanges: UiMessageSource.of(message.parts).protectedJoinedRanges,
    );
    cleanedContent = parsed.visibleContent;
    thinkingTexts.addAll(parsed.thinkingTexts);
    fromInlineThinking = parsed.hasThinking;
  }

  return ThinkingExportData(
    cleanedContent: cleanedContent,
    thinkingTexts: thinkingTexts,
    fromInlineThinking: fromInlineThinking,
  );
}

void _addReasoningSegmentTexts(List<String> output, List<dynamic> segments) {
  for (final item in segments) {
    if (item is Map) {
      final t = (item['text']?.toString() ?? '').trim();
      if (t.isNotEmpty) output.add(t);
    }
  }
}
