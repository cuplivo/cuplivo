import 'dart:convert';

import '../../utils/app_directories.dart';

typedef BusinessEntityRowIds = Map<String, List<String>>;

typedef BusinessSettingsExport = ({
  Map<String, Object> settings,
  BusinessEntityRowIds entityRowIds,
});

enum BusinessEntityKind {
  assistant(sourceKey: 'assistants_v1', tableName: 'assistant_rows'),
  provider(sourceKey: 'provider_configs_v1', tableName: 'provider_rows'),
  providerGroup(
    sourceKey: 'provider_groups_v1',
    tableName: 'provider_group_rows',
  ),
  mcpServer(sourceKey: 'mcp_servers_v1', tableName: 'mcp_server_rows'),
  worldBook(sourceKey: 'world_books_v1', tableName: 'world_book_rows'),
  assistantMemory(
    sourceKey: 'assistant_memories_v1',
    tableName: 'assistant_memory_rows',
  ),
  quickPhrase(sourceKey: 'quick_phrases_v1', tableName: 'quick_phrase_rows'),
  searchService(
    sourceKey: 'search_services_v1',
    tableName: 'search_service_rows',
  ),
  ttsService(sourceKey: 'tts_services_v1', tableName: 'tts_service_rows'),
  instructionInjection(
    sourceKey: 'instruction_injections_v1',
    tableName: 'instruction_injection_rows',
  ),
  assistantTag(sourceKey: 'assistant_tags_v1', tableName: 'assistant_tag_rows'),
  memoryEntry(sourceKey: 'memory_entries_v1', tableName: 'memory_entry_rows'),
  workspace(
    sourceKey: 'workspaces_v1',
    tableName: 'extension_entity_rows',
    extensionKind: 'workspace',
  ),
  skill(
    sourceKey: 'skills_v1',
    tableName: 'extension_entity_rows',
    extensionKind: 'skill',
  ),
  userProfileField(
    sourceKey: 'user_profile_fields_v1',
    tableName: 'user_profile_field_rows',
  );

  const BusinessEntityKind({
    required this.sourceKey,
    required this.tableName,
    this.extensionKind,
  });

  final String sourceKey;
  final String tableName;
  final String? extensionKind;

  /// Identity of this kind on the sync wire. Ordinary kinds travel under
  /// their table name; extension kinds share `extension_entity_rows`, so
  /// they travel under their extension kind (`skill`) — the wire name must
  /// be 1:1 with a kind, and the SQL filters by the kind column.
  String get wireName => extensionKind ?? tableName;

  String get idColumn => this == provider ? 'provider_key' : 'id';
}

/// Whether one workspace payload describes a *linked* folder — a directory the
/// user already had, which Cuplivo merely points at — rather than a managed
/// workspace, whose directory Cuplivo owns and can copy.
///
/// The distinction is the whole of workspace portability: a linked workspace is
/// a place on *one* machine's filesystem, so its row can neither travel in a
/// backup nor ride LAN sync. Both rules read this predicate so the two can never
/// drift into disagreeing about what "linked" means; a payload that cannot be
/// read is treated as ordinary, so a corrupt row is carried as a managed
/// workspace instead of being silently hidden — nothing here ever reads the
/// linked path itself, and the content plane only ever resolves managed folders
/// under Cuplivo's own `<appData>/workspaces/<id>/files`.
bool isLinkedWorkspace(String payload) {
  final Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } on FormatException {
    return false;
  }
  return decoded is Map && decoded['kind'] == 'linked';
}

/// One payload as a decoded JSON object, or null when it is not one.
///
/// The decode every rule that reads a payload shares, so "this payload is not
/// an object" is one answer instead of one per caller.
Map<String, dynamic>? decodePayloadObject(String payload) {
  final Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  return decoded.map((key, value) => MapEntry(key.toString(), value));
}

/// Whether one decoded workspace payload names exactly [rowId] as its own id —
/// and that id may name a directory under `<appData>/workspaces`.
///
/// A workspace carries its identity twice: the table's `id` column decides what
/// the row *is*, while the payload's own `id` is what the app reads
/// (`Workspace.fromJson`) and therefore what names
/// `<appData>/workspaces/<id>/files` and what a delete removes. When the two
/// disagree, the payload's is the one nothing else validated: the provider
/// lists the workspace under it, an update mints a second row under it, and a
/// delete with files builds `<appData>/workspaces/..` for `..` — which is the
/// app data root itself. A row whose halves disagree is malformed, and every
/// face that offers, serves, applies, lists or deletes a workspace reads this
/// one rule.
bool workspacePayloadNamesId(Map<String, dynamic> payload, String rowId) {
  final id = payload['id'];
  return id is String && id == rowId && isSafeWorkspaceId(id);
}

final class BusinessEntityValue {
  const BusinessEntityValue({
    required this.id,
    required this.sortOrder,
    required this.payload,
    this.assistantId,
  });

  final String id;
  final int sortOrder;
  final String payload;
  final String? assistantId;

  BusinessEntityValue copyWith({
    String? id,
    int? sortOrder,
    String? payload,
    String? assistantId,
  }) => BusinessEntityValue(
    id: id ?? this.id,
    sortOrder: sortOrder ?? this.sortOrder,
    payload: payload ?? this.payload,
    assistantId: assistantId ?? this.assistantId,
  );
}

final class BusinessSnapshot {
  BusinessSnapshot({
    required Map<BusinessEntityKind, List<BusinessEntityValue>> entities,
    required Map<String, Object> preferences,
  }) : entities = {
         for (final kind in BusinessEntityKind.values)
           kind: List<BusinessEntityValue>.unmodifiable(
             entities[kind] ?? const <BusinessEntityValue>[],
           ),
       },
       preferences = Map<String, Object>.unmodifiable(preferences);

  final Map<BusinessEntityKind, List<BusinessEntityValue>> entities;
  final Map<String, Object> preferences;

  int entityCount(BusinessEntityKind kind) => entities[kind]!.length;
}
