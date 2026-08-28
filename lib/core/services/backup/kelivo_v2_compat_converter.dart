/// In-place conversion of upstream Kelivo v2 (v1.2.0) backups into the
/// legacy `chats.json` v1 layout this app restores.
///
/// Port of the kelivo-helper compat pipeline
/// (https://github.com/cup113/kelivo-helper — src/lib/{compat,cuplivo,kelivo-v120}),
/// so a Kelivo v2 backup (`manifest.json` + `database/kelivo.db`) can be
/// imported directly instead of being routed through the external website.
///
/// The converter runs on an extracted backup directory (the temp dir created
/// by the restore flow) and mutates it in place:
///   manifest.json (deleted after success)
///   database/kelivo.db (read-only; left in place, ignored by restore)
///   settings.json (rewritten: assistant-layer surgery + memory downgrade +
///                  search-services surgery; other keys pass through)
///   chats.json (written: full-fidelity flatten of conversations/messages)
///   deleted.json (written: `{}`)
///   upload/ avatars/ images/ fonts/ (already extracted; consumed by restore)
///
/// Deliberate deviations from the website pipeline (documented in the PR):
///   * `payloadKind === 'settings-only'` → no `chats.json` is written. The
///     website emits an empty one; here an empty blob in overwrite mode would
///     wipe the device's local chats via `clearAllData()`.
///   * Same skip applies when `database/kelivo.db` is missing/unreadable.
///   * The `stringifySettingsJson` double-key text patch from the website is
///     unnecessary here: Dart distinguishes `1.0` (double) from `1` (int)
///     through `jsonDecode`/`jsonEncode`, so doubles round-trip natively.
///
/// Unknown manifest formats/versions still throw [KelivoV2BackupException]
/// so the UI can offer the kelivo-helper fallback dialog.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'kelivo_v2_exception.dart';

/// Managed media roots Kelivo uses inside a backup zip (website
/// `MANAGED_ROOTS`).
const List<String> _managedRoots = ['upload', 'images', 'avatars', 'fonts'];

/// `chats.json` version constant — locked to 1 (upstream cuplivo/cuplivo#453).
const int _chatsJsonVersion = 1;

/// Summary of a successful in-place conversion.
class KelivoV2CompatResult {
  const KelivoV2CompatResult({
    required this.warnings,
    required this.drops,
    required this.settingsOnly,
    required this.conversations,
    required this.messages,
    required this.toolEvents,
    required this.geminiSignatures,
    required this.memories,
  });

  /// Non-fatal notes collected while converting (mirrors the website report).
  final List<String> warnings;

  /// Category -> dropped item count (mirrors the website report "drop" tally).
  final Map<String, int> drops;

  /// True when the backup carried no chat payload (`payloadKind
  /// settings-only`, or the DB was unreadable) — no `chats.json` was written.
  final bool settingsOnly;

  final int conversations;
  final int messages;
  final int toolEvents;
  final int geminiSignatures;
  final int memories;

  @override
  String toString() =>
      'KelivoV2CompatResult(conversations: $conversations, messages: $messages, '
      'toolEvents: $toolEvents, geminiSignatures: $geminiSignatures, '
      'memories: $memories, settingsOnly: $settingsOnly, '
      'warnings: ${warnings.length}, drops: $drops)';
}

/// Converts an extracted Kelivo v2 backup directory in place so the standard
/// legacy restore path can consume it.
///
/// Throws [KelivoV2BackupException] when the manifest is missing or announces
/// an unsupported format/version — the caller's catch site shows the
/// kelivo-helper fallback dialog. Other errors propagate as generic restore
/// failures (nothing local has been touched at that point).
Future<KelivoV2CompatResult> convertKelivoV2BackupInPlace(
  String extractDirPath,
) {
  // Heavy work (SQLite reads + JSON assembly) runs in a background isolate
  // to keep the UI responsive, mirroring how ZIP extraction already runs.
  return Isolate.run(() => _convertInIsolate(extractDirPath));
}

KelivoV2CompatResult _convertInIsolate(String dirPath) {
  final report = _Report();
  final dir = Directory(dirPath);
  if (!dir.existsSync()) throw const KelivoV2BackupException();

  // --- manifest validation -------------------------------------------------
  final manifestFile = File(p.join(dirPath, 'manifest.json'));
  if (!manifestFile.existsSync()) throw const KelivoV2BackupException();
  final manifest = _parseManifest(manifestFile.readAsStringSync());
  if (manifest == null) throw const KelivoV2BackupException();
  if (manifest.formatVersion != 2) {
    // Unknown upstream format version — not auto-convertible.
    throw const KelivoV2BackupException();
  }
  final settingsOnlyKind = manifest.payloadKind == 'settings-only';

  // --- source settings ------------------------------------------------------
  Map<String, dynamic> settings = <String, dynamic>{};
  final settingsFile = File(p.join(dirPath, 'settings.json'));
  if (settingsFile.existsSync()) {
    try {
      final decoded = jsonDecode(settingsFile.readAsStringSync());
      if (decoded is Map<String, dynamic>) settings = decoded;
    } catch (_) {
      settings = <String, dynamic>{};
    }
  }
  if (settings.isEmpty) {
    report.warnings.add('settings.json 缺失或无法解析——助手/提供商/设置无法迁移。');
  }

  // --- chats: read kelivo.db and build the legacy chats.json blob ----------
  var settingsOnly = settingsOnlyKind;
  int conversations = 0;
  int messages = 0;
  if (!settingsOnly) {
    Map<String, dynamic>? chats;
    final dbFile = File(p.join(dirPath, 'database', 'kelivo.db'));
    if (dbFile.existsSync()) {
      try {
        chats = _buildChats(dbFile.path, dirPath, report);
      } catch (e) {
        // Safety deviation from the website: an unreadable database must not
        // produce an empty chats.json (overwrite restore would wipe local
        // chats). Skip chats entirely and let the user re-export upstream.
        report.warnings.add('database/kelivo.db 读取失败，会话/消息未迁移: $e');
      }
    } else {
      report.warnings.add('未找到 database/kelivo.db——会话/消息无法迁移。');
    }
    if (chats != null) {
      File(
        p.join(dirPath, 'chats.json'),
      ).writeAsStringSync(jsonEncode(chats));
      conversations = report.conversations;
      messages = report.messages;
    } else {
      settingsOnly = true;
    }
  }

  // --- settings: pass-through + assistant/memory/search surgery ------------
  final transformed = _transformSettings(settings, report);
  if (transformed.isNotEmpty) {
    // Dart jsonEncode keeps double-ness (1.0 stays "1.0"), so prefs.getDouble
    // keys round-trip safely — no website-style text patch needed.
    settingsFile.writeAsStringSync(jsonEncode(transformed));
  }

  // --- deleted.json tombstone (empty; website emits the same) --------------
  File(p.join(dirPath, 'deleted.json')).writeAsStringSync('{}');

  // --- manifest consumed ----------------------------------------------------
  try {
    manifestFile.deleteSync();
  } catch (_) {}

  return KelivoV2CompatResult(
    warnings: List<String>.of(report.warnings),
    drops: Map<String, int>.of(report.drops),
    settingsOnly: settingsOnly,
    conversations: conversations,
    messages: messages,
    toolEvents: report.toolEvents,
    geminiSignatures: report.geminiSignatures,
    memories: report.memories,
  );
}

class _KelivoManifest {
  _KelivoManifest({
    required this.format,
    required this.formatVersion,
    required this.payloadKind,
  });

  final String format;
  final int formatVersion;
  final String payloadKind;
}

_KelivoManifest? _parseManifest(String text) {
  Object? obj;
  try {
    obj = jsonDecode(text);
  } catch (_) {
    return null;
  }
  if (obj is! Map) return null;
  final format = obj['format'];
  final version = obj['formatVersion'];
  final payloadKind = obj['payloadKind'];
  if (format is! String || version is! num) return null;
  if (payloadKind is! String ||
      (payloadKind != 'sqlite' && payloadKind != 'settings-only')) {
    return null;
  }
  if (obj['entries'] is! Map) return null;
  return _KelivoManifest(
    format: format,
    formatVersion: version.toInt(),
    payloadKind: payloadKind,
  );
}

/// Drop tally + warnings, mirroring the website `CompatReport` shape that the
/// conversion rules emit into (the website renders it; we log it).
class _Report {
  final List<String> warnings = <String>[];
  final Map<String, int> drops = <String, int>{};
  int conversations = 0;
  int messages = 0;
  int toolEvents = 0;
  int geminiSignatures = 0;
  int memories = 0;

  void drop(String reason, int count) {
    drops[reason] = (drops[reason] ?? 0) + count;
  }
}

/// epoch microseconds → `YYYY-MM-DDTHH:mm:ss.ffffffZ` (UTC, website
/// `microsToIso`).
String _microsToIso(int micros) {
  final ms = micros ~/ 1000;
  final microPart = ((micros % 1000) + 1000) % 1000;
  final dt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  final msPart = ((ms % 1000) + 1000) % 1000;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year.toString().padLeft(4, '0')}-${two(dt.month)}-'
      '${two(dt.day)}T${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}.'
      '${msPart.toString().padLeft(3, '0')}${microPart.toString().padLeft(3, '0')}Z';
}

String? _nullableMicrosToIso(Object? micros) =>
    micros is int ? _microsToIso(micros) : null;

/// Parses a JSON-string column with a fallback (website `parseJsonOr`).
T _parseJsonOr<T>(Object? raw, T fallback) {
  if (raw == null) return fallback;
  try {
    final parsed = jsonDecode(raw as String);
    if (parsed == null) return fallback;
    return parsed as T;
  } catch (_) {
    return fallback;
  }
}

// ---------------------------------------------------------------------------
// chats.json build (port of kelivo-v120/query.ts + cuplivo/chats.ts)
// ---------------------------------------------------------------------------

/// kelivo.db row shape used below — a plain map of snake_case columns.
typedef _Row = Map<String, Object?>;

Map<String, dynamic> _buildChats(
  String dbPath,
  String dirPath,
  _Report report,
) {
  final db = sqlite3.openReadOnly(dbPath);
  try {
    final convRows = db.select(
      'SELECT id, title, created_at, updated_at, is_pinned, assistant_id, '
      'truncate_index, version_selections_json, summary, '
      'last_summarized_message_count, chat_suggestions_json, '
      'injected_memory_hash, last_memory_extracted_order '
      'FROM conversation_rows',
    );
    final mcpRows = db.select(
      'SELECT conversation_id, server_id FROM conversation_mcp_server_rows '
      'ORDER BY conversation_id, ordinal',
    );
    final msgRows = db.select(
      'SELECT id, conversation_id, role, timestamp, model_id, provider_id, '
      'total_tokens, is_streaming, reasoning_start_at, '
      'reasoning_finished_at, translation, reasoning_segments_json, '
      'group_id, version, prompt_tokens, completion_tokens, cached_tokens, '
      'duration_ms, message_order '
      'FROM message_rows ORDER BY conversation_id, message_order',
    );
    final partRows = db.select(
      'SELECT part_id, conversation_id, revision_id, ordinal, kind, payload '
      'FROM message_part_rows ORDER BY revision_id, ordinal',
    );
    final sigRows = db.select(
      "SELECT revision_id, kind, payload FROM provider_artifact_rows "
      "WHERE kind = 'gemini_thought_signature'",
    );
    final assetRows = db.select(
      'SELECT id, content_hash, path, byte_size FROM asset_rows',
    );
    final msgAssetRows = db.select(
      'SELECT revision_id, asset_id FROM message_asset_rows '
      'ORDER BY revision_id',
    );

    final mcpsByConv = <String, List<String>>{};
    for (final r in mcpRows) {
      mcpsByConv
          .putIfAbsent(r['conversation_id'] as String, () => <String>[])
          .add(r['server_id'] as String);
    }

    final idsByConv = <String, List<String>>{};
    for (final r in msgRows) {
      idsByConv
          .putIfAbsent(r['conversation_id'] as String, () => <String>[])
          .add(r['id'] as String);
    }

    final partsByRevision = <String, List<_Row>>{};
    for (final row in partRows) {
      partsByRevision
          .putIfAbsent(row['revision_id'] as String, () => <_Row>[])
          .add(row);
    }

    final assetsById = <String, _Row>{
      for (final a in assetRows) a['id'] as String: a,
    };
    final assetPathById = <String, String>{};
    for (final link in msgAssetRows) {
      final assetId = link['asset_id'] as String;
      final asset = assetsById[assetId];
      if (asset != null && !assetPathById.containsKey(assetId)) {
        assetPathById[assetId] = asset['path'] as String;
      }
    }

    bool zipHas(String path) =>
        File(p.join(dirPath, path)).existsSync();

    final toolEvents = <String, List<Object?>>{};
    final messages = <Map<String, dynamic>>[];
    for (final row in msgRows) {
      final id = row['id'] as String;
      final built = _buildMessage(
        row,
        partsByRevision[id] ?? const <_Row>[],
        zipHas,
        assetPathById,
        report,
      );
      if (built.toolEvents.isNotEmpty) toolEvents[id] = built.toolEvents;
      messages.add(built.message);
    }

    final geminiThoughtSigs = <String, String>{
      for (final sig in sigRows)
        sig['revision_id'] as String: sig['payload'] as String,
    };

    final conversations = <Map<String, dynamic>>[
      for (final row in convRows)
        _buildConversation(row, mcpsByConv, idsByConv),
    ];

    report.conversations = conversations.length;
    report.messages = messages.length;
    report.toolEvents = toolEvents.values.fold(0, (n, e) => n + e.length);
    report.geminiSignatures = geminiThoughtSigs.length;

    return <String, dynamic>{
      'version': _chatsJsonVersion,
      'conversations': conversations,
      'messages': messages,
      'toolEvents': toolEvents,
      'geminiThoughtSigs': geminiThoughtSigs,
      'groupChats': <Object?>[],
      'groupMembers': <Object?>[],
    };
  } finally {
    db.dispose();
  }
}

Map<String, dynamic> _buildConversation(
  _Row row,
  Map<String, List<String>> mcpsByConv,
  Map<String, List<String>> idsByConv,
) {
  return <String, dynamic>{
    'id': row['id'],
    'title': row['title'],
    'createdAt': _microsToIso(row['created_at'] as int),
    'updatedAt': _microsToIso(row['updated_at'] as int),
    'messageIds': idsByConv[row['id'] as String] ?? const <String>[],
    'isPinned': (row['is_pinned'] as int? ?? 0) != 0,
    'mcpServerIds': mcpsByConv[row['id'] as String] ?? const <String>[],
    'assistantId': row['assistant_id'] as String?,
    'parentConversationId': null,
    'truncateIndex': row['truncate_index'],
    'versionSelections': _parseJsonOr<Map<String, dynamic>>(
      row['version_selections_json'],
      <String, dynamic>{},
    ),
    'summary': row['summary'] as String?,
    'lastSummarizedMessageCount': row['last_summarized_message_count'],
    'chatSuggestions': _parseJsonOr<List<dynamic>>(
      row['chat_suggestions_json'],
      <dynamic>[],
    ),
    'conversationKind': 'normal',
    // kelivo v1.2.0-only fields (fidelity pass-through; Cuplivo ignores).
    'injectedMemoryHash': row['injected_memory_hash'] as String?,
    'lastMemoryExtractedOrder': row['last_memory_extracted_order'],
  };
}

class _BuiltMessage {
  _BuiltMessage({required this.message, required this.toolEvents});

  final Map<String, dynamic> message;
  final List<Object?> toolEvents;
}

class _FlattenedPart {
  _FlattenedPart({
    required this.text,
    required this.toolEvent,
    required this.isReasoning,
  });

  final String text;
  final Object? toolEvent;
  final bool isReasoning;
}

_BuiltMessage _buildMessage(
  _Row row,
  List<_Row> parts,
  bool Function(String) zipHas,
  Map<String, String> assetPathById,
  _Report report,
) {
  var content = '';
  final reasoning = <String>[];
  final toolEvents = <Object?>[];
  for (final part in parts) {
    final f = _flattenPart(
      part['kind'] as String,
      part['payload'] as String,
      zipHas,
      assetPathById,
      report,
    );
    if (f.isReasoning) {
      if (f.text.isNotEmpty) reasoning.add(f.text);
    } else {
      content += f.text;
    }
    final event = f.toolEvent;
    if (event != null) toolEvents.add(event);
  }
  return _BuiltMessage(
    message: <String, dynamic>{
      'id': row['id'],
      'role': row['role'],
      'content': content,
      'timestamp': _microsToIso(row['timestamp'] as int),
      'modelId': row['model_id'] as String?,
      'providerId': row['provider_id'] as String?,
      'totalTokens': row['total_tokens'] as int?,
      'conversationId': row['conversation_id'],
      'isStreaming': (row['is_streaming'] as int? ?? 0) != 0,
      'reasoningText': reasoning.isNotEmpty ? reasoning.join('\n') : null,
      'reasoningStartAt': _nullableMicrosToIso(row['reasoning_start_at']),
      'reasoningFinishedAt': _nullableMicrosToIso(
        row['reasoning_finished_at'],
      ),
      'translation': row['translation'] as String?,
      'reasoningSegmentsJson': row['reasoning_segments_json'] as String?,
      'groupId': row['group_id'] as String?,
      'subgroupId': null,
      'version': row['version'],
      'promptTokens': row['prompt_tokens'] as int?,
      'completionTokens': row['completion_tokens'] as int?,
      'cachedTokens': row['cached_tokens'] as int?,
      'durationMs': row['duration_ms'] as int?,
      'isPreset': false,
      'speakerAssistantId': null,
    },
    toolEvents: toolEvents,
  );
}

// --- media reference resolution (website chats.ts) -------------------------

/// Absolute path → portable slash path; strips `file:` scheme; rejects UNC.
String? _portableSlash(String path) {
  var v = path;
  if (RegExp(r'^file:', caseSensitive: false).hasMatch(v)) {
    final u = Uri.tryParse(v);
    if (u == null) return null;
    if (u.host.isNotEmpty && u.host != 'localhost') return null;
    try {
      v = Uri.decodeComponent(u.path);
    } catch (_) {
      return null;
    }
    if (RegExp(r'^\/[A-Za-z]:').hasMatch(v)) v = v.substring(1);
  }
  if (v.startsWith('\\\\') || v.startsWith('//')) return null;
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(v)) {
    return v.replaceAll('\\', '/');
  }
  if (v.contains('\\')) return null;
  return v;
}

/// Locates a managed root inside a path, returning `root/rest` (root included).
String? _managedTail(String path) {
  final lower = path.toLowerCase();
  for (final root in _managedRoots) {
    final i = lower.indexOf('/$root/');
    if (i != -1) {
      final tail = path.substring(i + 1);
      if (tail.length > root.length + 1) return tail;
    }
  }
  return null;
}

/// `upload/x.png`-style relative path → validated root.
String? _relativeManaged(String path) {
  final m = RegExp(r'^([A-Za-z0-9_-]+)/(.+)$').firstMatch(path);
  if (m == null) return null;
  final root = m.group(1)!.toLowerCase();
  if (!_managedRoots.contains(root)) return null;
  final rest = m.group(2)!;
  if (rest.isEmpty || rest.contains('..')) return null;
  return '$root/$rest';
}

Map<String, Object?>? _parsePartPayload(String payload) {
  try {
    final parsed = jsonDecode(payload);
    if (parsed is Map) return parsed.cast<String, Object?>();
  } catch (_) {
    // fallthrough
  }
  return null;
}

/// Media reference → Cuplivo marker path (fidelity first; unmapped refs keep
/// their raw text and are counted in the report).
String? _resolveMediaRef(
  Object? uri,
  Object? assetId,
  bool Function(String) zipHas,
  Map<String, String> assetPathById,
  _Report report,
) {
  if (uri is! String || uri.isEmpty) return null;

  // Network / data URIs: verbatim (no leading slash).
  if (RegExp(r'^(https?:|data:)', caseSensitive: false).hasMatch(uri)) {
    return uri;
  }

  final assetPath =
      (assetId is String && assetId.isNotEmpty)
          ? assetPathById[assetId]
          : null;

  // kelivo-file:///root/rel → /root/rel (semantic location; falls back to the
  // media-library path when the file is absent from the zip).
  final kf = RegExp(r'^kelivo-file:///(.+)$').firstMatch(uri);
  if (kf != null) {
    String? rel;
    try {
      final segments = kf
          .group(1)!
          .split('/')
          .map((s) => Uri.decodeComponent(s))
          .toList();
      if (segments.length >= 2 &&
          !segments.any((s) => s.isEmpty || s == '.' || s == '..') &&
          _managedRoots.contains(segments[0].toLowerCase())) {
        segments[0] = segments[0].toLowerCase();
        rel = segments.join('/');
      }
    } catch (_) {
      // fallthrough
    }
    if (rel == null) {
      report.drop('kelivo-file: URI 无法解析（标记保留原文）', 1);
      return uri;
    }
    if (zipHas(rel)) return '/$rel';
    final lib =
        _managedTail(assetPath ?? '') ?? _relativeManaged(assetPath ?? '');
    if (lib != null && zipHas(lib)) return '/$lib';
    report.drop('媒体文件不在备份包中（标记保留路径，Cuplivo 将显示为缺失）', 1);
    return '/$rel';
  }

  // Absolute sandbox path / relative path: lexical mapping to a managed root.
  final portable = _portableSlash(uri);
  if (portable == null) {
    report.drop('媒体路径无法识别（标记保留原文）', 1);
    return uri;
  }
  final rel = _managedTail(portable) ?? _relativeManaged(portable);
  if (rel != null && (zipHas(rel) || portable != uri)) {
    return '/$rel';
  }
  if (rel != null) {
    report.drop('媒体文件不在备份包中（标记保留路径，Cuplivo 将显示为缺失）', 1);
    return '/$rel';
  }
  return portable;
}

_FlattenedPart _flattenPart(
  String kind,
  String payload,
  bool Function(String) zipHas,
  Map<String, String> assetPathById,
  _Report report,
) {
  switch (kind) {
    case 'text':
      return _FlattenedPart(
        text: payload,
        toolEvent: null,
        isReasoning: false,
      );
    case 'reasoning':
      return _FlattenedPart(
        text: payload,
        toolEvent: null,
        isReasoning: true,
      );
    case 'tool_call':
      try {
        final parsed = jsonDecode(payload);
        if (parsed is Map) {
          return _FlattenedPart(
            text: '',
            toolEvent: parsed,
            isReasoning: false,
          );
        }
        report.drop('tool_call 载荷非对象（丢弃）', 1);
      } catch (_) {
        report.drop('tool_call 载荷无法解析（丢弃）', 1);
      }
      return _FlattenedPart(text: '', toolEvent: null, isReasoning: false);
    case 'image':
      final parsed = _parsePartPayload(payload);
      if (parsed == null) {
        report.drop('image 部件损坏（丢弃）', 1);
        return _FlattenedPart(text: '', toolEvent: null, isReasoning: false);
      }
      final ref = _resolveMediaRef(
        parsed['uri'],
        parsed['assetId'],
        zipHas,
        assetPathById,
        report,
      );
      if (ref == null) {
        report.drop('image 部件损坏（丢弃）', 1);
        return _FlattenedPart(text: '', toolEvent: null, isReasoning: false);
      }
      return _FlattenedPart(
        text: '\n[image:$ref]',
        toolEvent: null,
        isReasoning: false,
      );
    case 'file':
      final parsed = _parsePartPayload(payload);
      if (parsed == null) {
        report.drop('file 部件损坏（丢弃）', 1);
        return _FlattenedPart(text: '', toolEvent: null, isReasoning: false);
      }
      final ref = _resolveMediaRef(
        parsed['uri'],
        parsed['assetId'],
        zipHas,
        assetPathById,
        report,
      );
      if (ref == null) {
        report.drop('file 部件损坏（丢弃）', 1);
        return _FlattenedPart(text: '', toolEvent: null, isReasoning: false);
      }
      final name = parsed['name'] is String && (parsed['name'] as String).isNotEmpty
          ? parsed['name'] as String
          : 'file';
      final mime = parsed['mime'] is String && (parsed['mime'] as String).isNotEmpty
          ? parsed['mime'] as String
          : 'application/octet-stream';
      return _FlattenedPart(
        text: '\n[file:$ref|$name|$mime]',
        toolEvent: null,
        isReasoning: false,
      );
    default:
      // Unknown part type: keep verbatim in content (fidelity) + report.
      report.drop('未知消息部件类型「$kind」（原样保留到 content）', 1);
      return _FlattenedPart(text: payload, toolEvent: null, isReasoning: false);
  }
}

// ---------------------------------------------------------------------------
// settings.json surgery (port of cuplivo/settings.ts + compat/memory.ts)
// ---------------------------------------------------------------------------

/// Pass-through of the prefs snapshot except for three surgical fixes whose
/// upstream shapes Cuplivo cannot read (presetMessages string, new memory
/// format, search apiKeys string pool).
Map<String, dynamic> _transformSettings(
  Map<String, dynamic> sourceSettings,
  _Report report,
) {
  final out = Map<String, dynamic>.of(sourceSettings);
  if (out.containsKey('assistants_v1')) {
    final transformed = _transformAssistantsV1(out['assistants_v1'], report);
    if (transformed != null) out['assistants_v1'] = transformed;
  }
  _transformMemories(out, report);
  _transformSearchServicesV1(out, report);
  return out;
}

String? _transformAssistantsV1(Object? raw, _Report report) {
  if (raw is! String || raw.isEmpty) return null;
  Object? list;
  try {
    list = jsonDecode(raw);
  } catch (_) {
    report.warnings.add('assistants_v1 不是合法 JSON 字符串，助手层原样保留。');
    return raw;
  }
  if (list is! List) {
    report.warnings.add('assistants_v1 不是数组，助手层原样保留。');
    return raw;
  }

  var presetFixed = 0;
  var presetUnparsable = 0;
  var recallMapped = 0;

  final out = list.map((a) {
    if (a is! Map) return a;
    final rec = Map<String, dynamic>.from(a);

    // 1. presetMessages string → inline array.
    final pm = rec['presetMessages'];
    if (pm is String) {
      try {
        final parsed = jsonDecode(pm);
        if (parsed is List) {
          rec['presetMessages'] = parsed;
          presetFixed++;
        } else {
          presetUnparsable++;
        }
      } catch (_) {
        presetUnparsable++;
      }
    }

    // 2. Synthesize the legacy enableRecentChatsReference key.
    if (rec['allowPastConversationRecall'] is bool &&
        !rec.containsKey('enableRecentChatsReference')) {
      rec['enableRecentChatsReference'] = rec['allowPastConversationRecall'];
      recallMapped++;
    }

    return rec;
  }).toList();

  if (presetUnparsable > 0) {
    report.drop('presetMessages 无法解析（保持原样，Cuplivo 将忽略）', presetUnparsable);
  }
  if (presetFixed > 0 || recallMapped > 0) {
    report.warnings.add(
      '助手层手术：$presetFixed 个 presetMessages 字符串已重排为数组，'
      '$recallMapped 个 allowPastConversationRecall 已合成 enableRecentChatsReference。',
    );
  }
  return jsonEncode(out);
}

/// Kelivo serializes the extra search-service key pool as `apiKeys:
/// List<String>`, while Cuplivo's readKeys casts it to ApiKeyConfig objects —
/// pass-through would crash on restore. Convert: primary key first, string →
/// `{key}` object; Cuplivo's fromJson fills the remaining defaults.
void _transformSearchServicesV1(
  Map<String, dynamic> sourceSettings,
  _Report report,
) {
  final blob = sourceSettings['search_services_v1'];
  if (blob is! String || blob.isEmpty) return;

  Object? list;
  try {
    list = jsonDecode(blob);
  } catch (_) {
    report.warnings.add('search_services_v1 不是合法 JSON 字符串，搜索配置原样保留。');
    return;
  }
  if (list is! List) return;

  var fixed = 0;
  var mixed = 0;
  final outList = list.map((entry) {
    if (entry is! Map) return entry;
    final rec = Map<String, dynamic>.from(entry);
    final apiKeys = rec['apiKeys'];
    if (apiKeys is! List || apiKeys.isEmpty) return rec;
    if (!apiKeys.every((k) => k is String)) {
      mixed++;
      return rec;
    }
    final primary = rec['apiKey'];
    final pool = <String>[
      if (primary is String && primary.isNotEmpty) primary,
      ...(apiKeys.cast<String>()),
    ];
    rec['apiKeys'] = [for (final key in pool) {'key': key}];
    fixed++;
    return rec;
  }).toList();

  if (fixed > 0) {
    sourceSettings['search_services_v1'] = jsonEncode(outList);
    report.warnings.add(
      '搜索服务手术：$fixed 个服务的 apiKeys 字符串池已转为 ApiKeyConfig 列表'
      '（Cuplivo 读取时补默认字段）。',
    );
  }
  if (mixed > 0) {
    report.drop('搜索服务：apiKeys 含非字符串元素（保持原样）', mixed);
  }
}

/// Same shape as Kelivo's MemoryEntry.normalizeContent: trim + whitespace
/// fold + lowercase.
String _normalizeContent(String content) =>
    content.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

List<dynamic>? _parseJsonArray(Object? value) {
  if (value is! String || value.isEmpty) return null;
  try {
    final parsed = jsonDecode(value);
    return parsed is List ? parsed : null;
  } catch (_) {
    return null;
  }
}

List<String> _assistantIdsOf(Object? blob) {
  final list = _parseJsonArray(blob);
  if (list == null) return const <String>[];
  final ids = <String>[];
  for (final a in list) {
    if (a is! Map) continue;
    final id = a['id'];
    if (id is String) ids.add(id);
  }
  return ids;
}

/// Memory downgrade: Kelivo v1.2.0 new-format memories (`memory_entries_v1`)
/// → legacy `assistant_memories_v1` records Cuplivo actually reads
/// (issue cuplivo/cuplivo#543). Rules ruled on upstream:
/// scope=assistant maps 1:1; scope=global copies to every assistant;
/// archived is dropped; migrationIds supersede legacy records exactly, with
/// an (assistantId, normalizedContent) fallback dedupe.
void _transformMemories(Map<String, dynamic> sourceSettings, _Report report) {
  final newBlob = sourceSettings['memory_entries_v1'];
  if (newBlob == null) return;

  // Remove the new key: Cuplivo never reads it and restore would persist a
  // dead prefs entry.
  sourceSettings.remove('memory_entries_v1');

  final entries = _parseJsonArray(newBlob);
  if (entries == null) {
    if (newBlob is String) {
      report.warnings.add('memory_entries_v1 不是合法 JSON 字符串，新版记忆未转换（键已移除）。');
    }
    return;
  }

  // Legacy records (open merge).
  final legacy = <Map<String, dynamic>>[];
  var legacyInvalid = 0;
  final legacyParsed = _parseJsonArray(sourceSettings['assistant_memories_v1']);
  if (legacyParsed != null) {
    for (final r in legacyParsed) {
      if (_isLegacyMemoryRecord(r)) {
        legacy.add(r);
      } else {
        legacyInvalid++;
      }
    }
  } else if (sourceSettings['assistant_memories_v1'] is String) {
    report.warnings.add('assistant_memories_v1 不是合法 JSON，按空列表处理。');
  }

  // New entries: deterministic order (createdAt asc, then id); validate.
  var malformed = 0;
  final processed = <Map<String, dynamic>>[];
  for (final e in entries) {
    if (e is Map) {
      processed.add(Map<String, dynamic>.from(e));
    } else {
      malformed++;
    }
  }
  processed.sort((a, b) {
    final at = (a['createdAt'] as num?)?.toInt() ?? 0;
    final bt = (b['createdAt'] as num?)?.toInt() ?? 0;
    if (at != bt) return at.compareTo(bt);
    return '${a['id'] ?? ''}'.compareTo('${b['id'] ?? ''}');
  });

  final assistantIds = _assistantIdsOf(sourceSettings['assistants_v1']);
  final superseded = <int>{};
  final seenKeys = <String>{};
  final newRecords = <({String assistantId, String content})>[];
  var archived = 0;
  var globalNoAssistants = 0;
  var globalCopies = 0;

  bool addFor(Map<String, dynamic> e, String assistantId) {
    final content = e['content'] as String;
    final key = '$assistantId\n${_normalizeContent(content)}';
    if (seenKeys.contains(key)) return false;
    seenKeys.add(key);
    newRecords.add((assistantId: assistantId, content: content));
    return true;
  }

  for (final e in processed) {
    final status = e['status'];
    if (status == 'archived') {
      archived++;
      continue;
    }
    if (status != null && status != 'active') {
      malformed++;
      continue;
    }
    final content = e['content'];
    if (content is! String || content.isEmpty) {
      malformed++;
      continue;
    }
    final migrationIds = e['migrationIds'];
    if (migrationIds is List) {
      for (final id in migrationIds) {
        if (id is int) superseded.add(id);
      }
    }

    final scope = e['scope'];
    if (scope == 'assistant') {
      final assistantId = e['assistantId'];
      if (assistantId is String) {
        addFor(e, assistantId);
      } else {
        malformed++;
      }
    } else if (scope == 'global') {
      if (assistantIds.isEmpty) {
        globalNoAssistants++;
      } else {
        for (final aid in assistantIds) {
          if (addFor(e, aid)) globalCopies++;
        }
      }
    } else {
      malformed++;
    }
  }

  // Legacy merge: migrationIds supersede exactly + content-based fallback
  // dedupe (dupes among legacy records themselves are left untouched).
  final legacyKept = <Map<String, dynamic>>[];
  var supersededDropped = 0;
  var contentDupDropped = 0;
  for (final r in legacy) {
    final id = r['id'] as int;
    if (superseded.contains(id)) {
      supersededDropped++;
      continue;
    }
    final key =
        '${r['assistantId'] as String}\n'
        '${_normalizeContent(r['content'] as String)}';
    if (seenKeys.contains(key)) {
      contentDupDropped++;
      continue;
    }
    legacyKept.add(r);
  }

  var nextId = legacy.fold<int>(0, (m, r) => max(m, r['id'] as int)) + 1;
  final converted = <Map<String, dynamic>>[
    for (final r in newRecords)
      {'id': nextId++, 'assistantId': r.assistantId, 'content': r.content},
  ];
  final finalList = <Map<String, dynamic>>[...converted, ...legacyKept];

  if (finalList.isNotEmpty) {
    sourceSettings['assistant_memories_v1'] = jsonEncode(finalList);
  } else {
    sourceSettings.remove('assistant_memories_v1');
  }

  report.memories = finalList.length;
  if (archived > 0) report.drop('记忆：archived（旧版格式无此状态）', archived);
  if (globalNoAssistants > 0) {
    report.drop('记忆：global 但 assistants_v1 缺失/不可解析', globalNoAssistants);
  }
  if (malformed > 0) {
    report.drop('记忆：非法条目（scope/status/assistantId/content 不完整）', malformed);
  }
  if (legacyInvalid > 0) report.drop('记忆：非法旧版记录', legacyInvalid);
  if (converted.isNotEmpty) {
    report.warnings.add(
      '记忆转换：${processed.length} 个新版记忆 → ${converted.length} 条旧版记录'
      '${globalCopies > 0 ? '（global 复制 $globalCopies 份）' : ''}'
      '；取代旧记录 $supersededDropped 条，内容去重 $contentDupDropped 条。',
    );
  }
}

bool _isLegacyMemoryRecord(Object? r) {
  if (r is! Map) return false;
  return r['id'] is int && r['assistantId'] is String && r['content'] is String;
}
