import '../../database/schema_columns.dart';

/// Which way a family of rows regards the other device.
enum SyncFamilyOwnership {
  /// Travels: the rows are part of what this device publishes and applies.
  synced,

  /// Stays here, and says why. A `deviceLocal` family is never read for a
  /// manifest, never offered in a payload and never indexed for a blob — the
  /// reason is what keeps that a decision instead of an omission.
  deviceLocal,
}

/// Who applies a conversation family's rows.
enum SyncFamilyApply {
  /// The merge body's own rules: the message union with its order
  /// re-derivation, the binding set replace. These are the families whose
  /// content is the conversation's text, and no row-level rule can express them.
  specialised,

  /// Row-level last-write-wins over the family's rows — the D-7 rule for a family
  /// stored as one document per conversation. A local copy that loses is
  /// replaced, and the session report counts it.
  rowLastWriteWins,
}

/// What a family belongs to.
enum SyncFamilyScope {
  /// Hung off one conversation: it rides (or refuses to ride) that
  /// conversation's subtree.
  conversation,

  /// A row of the shared library — assistants, world books, templates — which
  /// travels on the business face by kind and id, never inside a subtree.
  business,
}

/// How a family's content enters a conversation's identity.
///
/// This is the question the plan asks when it plans a session, so the answer
/// lives beside the family rather than inside one SQL statement: a family whose
/// content changed must be visible to the plan even when the conversation row
/// and its messages did not move.
enum SyncIdentityContribution {
  /// Contributes nothing.
  none,

  /// The conversation row's own clock, which the manifest entry already carries
  /// as `u`. Exactly one family claims this: the conversation itself.
  conversationClock,

  /// One `key:clock` line per row, where the clock is the row's `updated_at`
  /// against its `timestamp`. Cheap to aggregate in SQL, and sensitive to
  /// insert, edit and delete.
  rowClocks,

  /// One `key:value…` line per row, for a family that has no clock column — its
  /// values *are* its state.
  rowValues,

  /// One digest over the row's payload: the family is a whole document, so the
  /// payload is the only thing that can distinguish two revisions.
  payloadDigest,
}

/// One family of rows, registered once.
///
/// Both ends of sync read this registration — what to read for a subtree, what
/// to apply, what enters the identity, which columns may carry a blob URI — so a
/// new family is one entry here and no change to the wire struct. `ownership` is
/// the only field that decides whether the rest is acted on; `identity` and
/// `blobColumns` describe what the family contributes *when it travels*, which
/// is why a `deviceLocal` family may still name them.
class SyncFamily {
  const SyncFamily({
    required this.name,
    required this.table,
    this.kind,
    this.wireKey,
    this.conversationColumn = 'conversation_id',
    this.orderBy,
    this.isSubtreeRoot = false,
    this.apply = SyncFamilyApply.specialised,
    required this.ownership,
    this.deviceLocalReason,
    required this.scope,
    this.identity = SyncIdentityContribution.none,
    this.identityColumns = const [],
    this.blobColumns = const [],
  });

  /// Stable name, used in failure messages and tests. Not a wire value.
  final String name;

  /// The table the rows live in.
  final String table;

  /// `extension_entity_rows.kind` filter, for a family that shares that table
  /// with others. Null for every family that owns its table outright.
  final String? kind;

  /// The key this family's rows travel under inside a conversation subtree.
  ///
  /// It is spelled here so that adding a family is adding an entry: the payload
  /// is a map of these keys, not a struct whose fields somebody has to grow.
  /// Required for a synced conversation family, and unique among them.
  final String? wireKey;

  /// The column that names the conversation a row belongs to. `conversation_id`
  /// almost everywhere; `id` for the conversation itself and for the
  /// `extension_entity_rows` documents, which are keyed by the conversation's
  /// own id.
  final String conversationColumn;

  /// `ORDER BY` clause for this family's rows, so a sender and a sender's peer
  /// read the same order. Null when the family has one row per conversation.
  final String? orderBy;

  /// Whether this family *is* the subtree root: one row, travelling as the
  /// payload's `conversation` rather than as a list. Exactly one synced
  /// conversation family claims it.
  final bool isSubtreeRoot;

  /// Who applies this family's rows when they arrive.
  final SyncFamilyApply apply;

  final SyncFamilyOwnership ownership;

  /// Why this family stays on this device. Required for [deviceLocal] and
  /// forbidden for [synced].
  final String? deviceLocalReason;

  final SyncFamilyScope scope;

  /// What this family contributes to a conversation's identity — for a
  /// `business` family, to the row's own manifest digest.
  final SyncIdentityContribution identity;

  /// The columns that name a row inside an [SyncIdentityContribution.rowClocks]
  /// or [SyncIdentityContribution.rowValues] line, in order.
  final List<String> identityColumns;

  /// The columns that may embed a `kelivo-file` URI, which is what the blob
  /// plane scans. Declared rather than guessed, so "which strings can reference
  /// a file" is answered once.
  final List<String> blobColumns;

  bool get isSynced => ownership == SyncFamilyOwnership.synced;
}

/// Every family of rows this build knows about.
///
/// The guard test (`test/core/services/sync/sync_family_registry_test.dart`)
/// fails when the source grows a kind that is not here, or when a table that
/// hangs off a conversation is here neither. Adding a family is adding an entry.
const List<SyncFamily> kSyncFamilies = [
  // ---- the conversation subtree -------------------------------------------
  SyncFamily(
    name: 'conversation',
    table: 'conversation_rows',
    wireKey: 'conversation',
    conversationColumn: 'id',
    isSubtreeRoot: true,
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.conversation,
    identity: SyncIdentityContribution.conversationClock,
    blobColumns: [
      'title',
      'summary',
      'extras_json',
      'chat_suggestions_json',
      'version_selections_json',
    ],
  ),
  SyncFamily(
    name: 'mcpBindings',
    table: 'conversation_mcp_server_rows',
    wireKey: 'mcpServers',
    orderBy: 'ordinal',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.conversation,
    // No clock column: the binding *is* its (server, ordinal) pair.
    identity: SyncIdentityContribution.rowValues,
    identityColumns: ['server_id', 'ordinal'],
  ),
  SyncFamily(
    name: 'messages',
    table: 'message_rows',
    wireKey: 'messages',
    orderBy: 'message_order, id',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.conversation,
    identity: SyncIdentityContribution.rowClocks,
    identityColumns: ['id'],
    blobColumns: ['translation', 'reasoning_segments_json', 'extras_json'],
  ),
  SyncFamily(
    name: 'messageParts',
    table: 'message_part_rows',
    wireKey: 'parts',
    orderBy: 'revision_id, ordinal',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.conversation,
    identity: SyncIdentityContribution.rowClocks,
    identityColumns: ['revision_id', 'ordinal'],
    blobColumns: ['payload'],
  ),

  // ---- families that hang off a conversation and do not travel yet ---------
  SyncFamily(
    name: 'providerArtifacts',
    table: 'provider_artifact_rows',
    wireKey: 'artifacts',
    orderBy: 'revision_id, kind',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.conversation,
    apply: SyncFamilyApply.rowLastWriteWins,
    identity: SyncIdentityContribution.rowClocks,
    identityColumns: ['revision_id', 'kind'],
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'conversationContext',
    table: 'extension_entity_rows',
    kind: 'conversationContext',
    wireKey: 'context',
    conversationColumn: 'id',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.conversation,
    apply: SyncFamilyApply.rowLastWriteWins,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'conversationImageContext',
    table: 'extension_entity_rows',
    kind: 'conversationImageContext',
    wireKey: 'imageContext',
    conversationColumn: 'id',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.conversation,
    apply: SyncFamilyApply.rowLastWriteWins,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'conversationCompression',
    table: 'extension_entity_rows',
    kind: 'conversationCompression',
    wireKey: 'compression',
    conversationColumn: 'id',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.conversation,
    apply: SyncFamilyApply.rowLastWriteWins,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'compressionTemplate',
    table: 'extension_entity_rows',
    kind: 'compressionTemplate',
    ownership: SyncFamilyOwnership.deviceLocal,
    deviceLocalReason:
        'A library template, shared by every conversation that names it — so it '
        'belongs on the business face, not in a subtree. This PR registers the '
        'kind there.',
    scope: SyncFamilyScope.business,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'compressionRecipe',
    table: 'extension_entity_rows',
    kind: 'compressionRecipe',
    ownership: SyncFamilyOwnership.deviceLocal,
    deviceLocalReason:
        'A library recipe over the templates, with the same standing as the '
        'templates themselves. This PR registers the kind on the business face.',
    scope: SyncFamilyScope.business,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),

  // ---- never leaves this device, and says why ------------------------------
  SyncFamily(
    name: 'compressionTask',
    table: 'extension_entity_rows',
    kind: 'contextCompressionTask',
    ownership: SyncFamilyOwnership.deviceLocal,
    deviceLocalReason:
        'A compression that is running on *this* device. The result lands on the '
        'rows it writes, which do travel; sending the task would ask the peer to '
        'repeat work it has no model call for.',
    scope: SyncFamilyScope.conversation,
  ),
  SyncFamily(
    name: 'composerDraft',
    table: 'extension_entity_rows',
    kind: 'composerDraft',
    ownership: SyncFamilyOwnership.deviceLocal,
    deviceLocalReason: 'What this device has typed but not sent.',
    scope: SyncFamilyScope.business,
  ),
  SyncFamily(
    name: 'composerNewEntry',
    table: 'extension_entity_rows',
    kind: 'composerNewEntry',
    ownership: SyncFamilyOwnership.deviceLocal,
    deviceLocalReason: 'A conversation opened but not yet created here.',
    scope: SyncFamilyScope.business,
  ),
  SyncFamily(
    name: 'composerShareReceipt',
    table: 'extension_entity_rows',
    kind: 'composerShareReceipt',
    ownership: SyncFamilyOwnership.deviceLocal,
    deviceLocalReason:
        'A record of a share *this* device performed; the peer performed none.',
    scope: SyncFamilyScope.business,
  ),
  SyncFamily(
    name: 'composerPrivateFile',
    table: 'extension_entity_rows',
    kind: 'composerPrivateFile',
    ownership: SyncFamilyOwnership.deviceLocal,
    deviceLocalReason: 'A file this device holds outside the managed roots.',
    scope: SyncFamilyScope.business,
  ),
  SyncFamily(
    name: 'composerPublishedFile',
    table: 'extension_entity_rows',
    kind: 'composerPublishedFile',
    ownership: SyncFamilyOwnership.deviceLocal,
    deviceLocalReason:
        'A published artefact of this device, named by a path only it has.',
    scope: SyncFamilyScope.business,
  ),
  SyncFamily(
    name: 'externalMounts',
    table: 'extension_entity_rows',
    kind: 'externalMounts',
    ownership: SyncFamilyOwnership.deviceLocal,
    deviceLocalReason:
        'A directory on this machine\'s filesystem. The peer has its own '
        'mounts, and a copied path would point at nothing.',
    scope: SyncFamilyScope.business,
  ),
  SyncFamily(
    name: 'generationRuns',
    table: 'generation_run_rows',
    ownership: SyncFamilyOwnership.deviceLocal,
    deviceLocalReason:
        'Bookkeeping for a generation streaming here. The message it writes '
        'travels; a peer adopting the run would hold a stream nothing feeds.',
    scope: SyncFamilyScope.conversation,
  ),
  SyncFamily(
    name: 'messagePrompts',
    table: 'message_prompt_rows',
    ownership: SyncFamilyOwnership.deviceLocal,
    deviceLocalReason:
        'The exact prompt each revision was sent with, kept for inspection. It '
        'is derived from rows that do travel, so a peer rebuilds it instead of '
        'receiving it.',
    scope: SyncFamilyScope.conversation,
  ),
  SyncFamily(
    name: 'messageAssets',
    table: 'message_asset_rows',
    ownership: SyncFamilyOwnership.deviceLocal,
    deviceLocalReason:
        'Which asset a revision references, re-derived here from the parts that '
        'arrive. The bytes travel on the blob plane by content hash.',
    scope: SyncFamilyScope.conversation,
  ),
  SyncFamily(
    name: 'genUiSurfaces',
    table: 'gen_ui_surface_state_rows',
    ownership: SyncFamilyOwnership.deviceLocal,
    deviceLocalReason:
        'Rendered surface state derived from the message it renders, rebuilt '
        'when that message arrives.',
    scope: SyncFamilyScope.conversation,
  ),
  SyncFamily(
    name: 'assetReferenceWorklist',
    table: 'asset_reference_dirty_rows',
    ownership: SyncFamilyOwnership.deviceLocal,
    deviceLocalReason:
        'A local worklist: these revisions\' asset references need re-deriving. '
        'It names work this device owes itself, not state a peer could use.',
    scope: SyncFamilyScope.conversation,
  ),

  // ---- the business face ---------------------------------------------------
  SyncFamily(
    name: 'assistants',
    table: 'assistant_rows',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.business,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'providers',
    table: 'provider_rows',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.business,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'providerGroups',
    table: 'provider_group_rows',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.business,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'mcpServers',
    table: 'mcp_server_rows',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.business,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'worldBooks',
    table: 'world_book_rows',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.business,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'assistantMemories',
    table: 'assistant_memory_rows',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.business,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'quickPhrases',
    table: 'quick_phrase_rows',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.business,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'searchServices',
    table: 'search_service_rows',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.business,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'ttsServices',
    table: 'tts_service_rows',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.business,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'instructionInjections',
    table: 'instruction_injection_rows',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.business,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'assistantTags',
    table: 'assistant_tag_rows',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.business,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'memoryEntries',
    table: 'memory_entry_rows',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.business,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'userProfileFields',
    table: 'user_profile_field_rows',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.business,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'workspaces',
    table: 'extension_entity_rows',
    kind: 'workspace',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.business,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'skills',
    table: 'extension_entity_rows',
    kind: 'skill',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.business,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'groupChats',
    table: 'extension_entity_rows',
    kind: 'groupChat',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.business,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['payload'],
  ),
  SyncFamily(
    name: 'preferences',
    table: 'preference_rows',
    ownership: SyncFamilyOwnership.synced,
    scope: SyncFamilyScope.business,
    identity: SyncIdentityContribution.payloadDigest,
    blobColumns: ['value'],
  ),
];

/// The family that owns [table] outright — the one with no kind filter.
SyncFamily syncFamilyOfTable(String table) {
  for (final family in kSyncFamilies) {
    if (family.table == table && family.kind == null) return family;
  }
  throw StateError('unregistered family: $table');
}

/// The family that names [table] and (when the family shares
/// `extension_entity_rows`) [kind].
SyncFamily? syncFamilyFor(String table, {String? kind}) {
  for (final family in kSyncFamilies) {
    if (family.table == table && family.kind == kind) return family;
  }
  return null;
}

/// The registered kind names, for the guard that compares them with the source.
Set<String> get registeredSyncKinds => {
  for (final family in kSyncFamilies)
    if (family.kind != null) family.kind!,
};

/// The families a conversation subtree carries, in wire order.
///
/// This list *is* what `readSubtree` reads and what a payload's JSON holds: a
/// family that is `synced` and conversation-scoped appears here without anyone
/// editing the read path.
List<SyncFamily> get syncedConversationFamilies => [
  for (final family in kSyncFamilies)
    if (family.isSynced && family.scope == SyncFamilyScope.conversation) family,
];

/// The families the business face carries.
List<SyncFamily> get syncedBusinessFamilies => [
  for (final family in kSyncFamilies)
    if (family.isSynced && family.scope == SyncFamilyScope.business) family,
];

/// The tables a conversation hangs rows off: the conversation itself, and every
/// table carrying `conversation_id` or `revision_id`.
///
/// Derived from the schema the sync writer trusts, so a table that starts
/// hanging off a conversation joins the guard without anyone remembering to add
/// it.
Set<String> get conversationAttachedTables => {
  'conversation_rows',
  for (final table in currentSchemaColumns.keys)
    if (table != 'conversation_rows' &&
        (currentSchemaColumns[table]!.contains('conversation_id') ||
            currentSchemaColumns[table]!.contains('revision_id')))
      table,
};

/// Every kind literal that means an `extension_entity_rows.kind` in [source],
/// with the line it appears on.
///
/// A literal is claimed in one of two ways, because the two are not equally
/// informative:
///
/// * A *declaration* — `entityKind = '…'`, `extensionKind: '…'`,
///   `static const kind = '…'` — is a kind whatever its casing, so it is
///   claimed as written.
/// * A *use* — `kind = '…'`, `kind: '…'`, `kind.equals('…')`, `kind IN (…)` —
///   is claimed only when the literal is camelCase. That test is what separates
///   an extension kind from the snake_case/word-shaped kinds of the other
///   tables in the same files (`message_part_rows.kind` is `text`, `image`,
///   `tool_call`); without it the guard would ask for a registration for every
///   enum member in the codebase.
Map<String, List<String>> extensionKindsInSource(String source) {
  final declarations = [
    RegExp(r"""\bentityKind\s*=\s*'([A-Za-z]+)'"""),
    RegExp(r"""\bextensionKind\s*:\s*'([A-Za-z]+)'"""),
    RegExp(r"""static\s+const\s+(?:String\s+)?kind\s*=\s*'([A-Za-z]+)'"""),
  ];
  final uses = [
    RegExp(r"""\bkind\s*=\s*'([A-Za-z]+)'"""),
    RegExp(r"""\bkind\s*:\s*'([A-Za-z]+)'"""),
    RegExp(r"""kind\.equals\(\s*'([A-Za-z]+)'\s*\)"""),
  ];
  final inList = RegExp(r"""\bkind\s+IN\s*\(([^)]*)\)""");
  final quoted = RegExp(r"""'([A-Za-z]+)'""");
  final found = <String, List<String>>{};
  final lines = source.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    void claim(String literal) => (found[literal] ??= []).add('line ${i + 1}');
    for (final pattern in declarations) {
      for (final match in pattern.allMatches(line)) {
        claim(match.group(1)!);
      }
    }
    for (final pattern in uses) {
      for (final match in pattern.allMatches(line)) {
        final literal = match.group(1)!;
        if (literal.contains(RegExp('[A-Z]'))) claim(literal);
      }
    }
    for (final match in inList.allMatches(line)) {
      for (final literal
          in quoted.allMatches(match.group(1)!).map((m) => m.group(1)!)) {
        if (literal.contains(RegExp('[A-Z]'))) claim(literal);
      }
    }
  }
  return found;
}

/// Everything wrong with [families], as one list of sentences. Empty means the
/// registry holds.
///
/// A pure function over the list rather than a check on the constant, so the
/// guard test can feed it the violations it is supposed to catch and watch it
/// answer.
List<String> syncFamilyProblems(
  List<SyncFamily> families, {
  Map<String, List<String>> schema = currentSchemaColumns,
  Set<String> conversationTables = const {},
}) {
  final problems = <String>[];
  final names = <String>{};
  for (final family in families) {
    final where = family.name;
    if (!names.add(family.name)) {
      problems.add('$where: registered twice');
    }
    final columns = schema[family.table];
    if (columns == null) {
      problems.add('$where: table ${family.table} is not in the schema map');
      continue;
    }
    if (family.kind != null && family.table != 'extension_entity_rows') {
      problems.add(
        '$where: names a kind but its table is ${family.table}, which has none',
      );
    }
    if (family.table == 'extension_entity_rows' && family.kind == null) {
      problems.add('$where: shares extension_entity_rows without a kind');
    }
    switch (family.ownership) {
      case SyncFamilyOwnership.deviceLocal:
        if ((family.deviceLocalReason ?? '').trim().isEmpty) {
          problems.add('$where: deviceLocal without a reason');
        }
      case SyncFamilyOwnership.synced:
        if (family.deviceLocalReason != null) {
          problems.add('$where: synced but carries a device-local reason');
        }
        if (family.identity == SyncIdentityContribution.none) {
          problems.add('$where: synced but contributes nothing to an identity');
        }
    }
    final keyed =
        family.identity == SyncIdentityContribution.rowClocks ||
        family.identity == SyncIdentityContribution.rowValues;
    if (keyed && family.identityColumns.isEmpty) {
      problems.add('$where: ${family.identity.name} without identity columns');
    }
    if (!keyed && family.identityColumns.isNotEmpty) {
      problems.add(
        '$where: identity columns declared for ${family.identity.name}',
      );
    }
    for (final column in [...family.identityColumns, ...family.blobColumns]) {
      if (!columns.contains(column)) {
        problems.add('$where: column $column is not in ${family.table}');
      }
    }
    if (family.isSynced && family.scope == SyncFamilyScope.conversation) {
      if ((family.wireKey ?? '').trim().isEmpty) {
        problems.add('$where: travels in a subtree without a wire key');
      }
      if (!columns.contains(family.conversationColumn)) {
        problems.add(
          '$where: ${family.table} has no ${family.conversationColumn} column',
        );
      }
    }
    // Only a family that owns its table is checkable this way. A family living
    // in `extension_entity_rows` hangs off whatever its `owner_id` names, which
    // the schema map cannot say per kind — that attachment is the registration
    // itself.
    if (family.kind == null &&
        family.scope == SyncFamilyScope.conversation &&
        !conversationTables.contains(family.table)) {
      problems.add(
        '$where: conversation-scoped, but ${family.table} hangs off no '
        'conversation',
      );
    }
  }
  for (final table in conversationTables) {
    final covered = families.any((family) => family.table == table);
    if (!covered) {
      problems.add(
        '$table: hangs off a conversation but is registered nowhere',
      );
    }
  }
  final roots = families.where((family) => family.isSubtreeRoot).length;
  if (roots != 1) {
    problems.add('a subtree needs exactly one root family, found $roots');
  }
  // Two families writing the same key of one payload would trade rows: the
  // reader of the second would find the first's.
  final wireKeys = <String>{};
  for (final family in families) {
    if (!family.isSynced || family.scope != SyncFamilyScope.conversation) {
      continue;
    }
    final key = family.wireKey;
    if (key == null || key.isEmpty) continue;
    if (!wireKeys.add(key)) {
      problems.add('${family.name}: wire key $key is used twice');
    }
  }
  return problems;
}
