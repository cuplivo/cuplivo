import 'dart:convert';

/// Short tool names exposed to the model for a bound workspace.
class WorkspaceToolNames {
  const WorkspaceToolNames._();

  static const String read = 'read';
  static const String write = 'write';
  static const String patch = 'patch';
  static const String delete = 'delete';
  static const String glob = 'glob';
  static const String grep = 'grep';
  static const String outline = 'outline';
  static const String mkdir = 'mkdir';
  static const String move = 'move';
  static const String zip = 'zip';
  static const String unzip = 'unzip';
  static const String download = 'download';
  static const String shell = 'shell';

  /// Filesystem tools (excludes shell).
  static const List<String> filesystemTools = <String>[
    read,
    write,
    patch,
    delete,
    glob,
    grep,
    outline,
    mkdir,
    move,
    zip,
    unzip,
    download,
  ];

  static const List<String> allTools = <String>[...filesystemTools, shell];

  /// Default-on tools for new workspaces.
  static const List<String> defaultEnabled = <String>[read, write, patch];

  /// Tools that require user approval by default.
  static const List<String> defaultNeedsApproval = <String>[delete, shell];

  static bool isWorkspaceTool(String name) => allTools.contains(name);

  /// Fallback when a workspace has no per-tool approval map entry.
  static bool defaultApprovalFor(String name) =>
      defaultNeedsApproval.contains(name);
}

/// Per-dependency install preference (source + optional version pin).
class DependencyInstallPref {
  final String sourceId; // 'auto' | builtin id | 'custom'
  final String? customUrl;
  final String? version;

  const DependencyInstallPref({
    this.sourceId = 'auto',
    this.customUrl,
    this.version,
  });

  DependencyInstallPref copyWith({
    String? sourceId,
    String? customUrl,
    String? version,
    bool clearCustomUrl = false,
    bool clearVersion = false,
  }) => DependencyInstallPref(
    sourceId: sourceId ?? this.sourceId,
    customUrl: clearCustomUrl ? null : (customUrl ?? this.customUrl),
    version: clearVersion ? null : (version ?? this.version),
  );

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    if (customUrl != null) 'customUrl': customUrl,
    if (version != null) 'version': version,
  };

  factory DependencyInstallPref.fromJson(Map<String, dynamic> json) =>
      DependencyInstallPref(
        sourceId: (json['sourceId'] as String?)?.trim().isNotEmpty == true
            ? (json['sourceId'] as String).trim()
            : 'auto',
        customUrl: json['customUrl'] as String?,
        version: json['version'] as String?,
      );
}

/// Built-in dependency package ids (install order for UI).
class WorkspaceDependencyIds {
  const WorkspaceDependencyIds._();

  static const String base = 'base';
  static const String python = 'python';
  static const String nodejs = 'nodejs';
  static const String git = 'git';
  static const String office = 'office';
  static const String buildEssential = 'build_essential';

  static const List<String> ordered = <String>[
    base,
    python,
    nodejs,
    git,
    office,
    buildEssential,
  ];
}

/// A parallel, isolated workspace sandbox.
class Workspace {
  static const String defaultAlias = 'default';
  static const String defaultId = 'workspace_default';
  static const String legacyAlias = 'workspaces';

  final String id;
  final String displayName;
  final String alias;
  final int sortOrder;
  final Map<String, bool> tools;
  final Map<String, bool> toolApprovals;
  final bool shellEnabled;
  final String? customHostPath;
  final bool readOnly;
  final Map<String, DependencyInstallPref> dependencyPrefs;
  final DateTime createdAt;
  final DateTime updatedAt;

  Workspace({
    required this.id,
    required this.displayName,
    required this.alias,
    this.sortOrder = 0,
    Map<String, bool>? tools,
    Map<String, bool>? toolApprovals,
    this.shellEnabled = false,
    this.customHostPath,
    this.readOnly = false,
    Map<String, DependencyInstallPref>? dependencyPrefs,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : tools = Map<String, bool>.unmodifiable(
         tools ??
             {
               for (final t in WorkspaceToolNames.filesystemTools)
                 t: WorkspaceToolNames.defaultEnabled.contains(t),
               WorkspaceToolNames.shell: false,
             },
       ),
       toolApprovals = Map<String, bool>.unmodifiable(
         toolApprovals ??
             {
               for (final t in WorkspaceToolNames.allTools)
                 t: WorkspaceToolNames.defaultApprovalFor(t),
             },
       ),
       dependencyPrefs = Map<String, DependencyInstallPref>.unmodifiable(
         dependencyPrefs ?? const <String, DependencyInstallPref>{},
       ),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  factory Workspace.createDefault({String? displayName}) {
    final now = DateTime.now();
    return Workspace(
      id: defaultId,
      displayName: displayName ?? 'Default',
      alias: defaultAlias,
      sortOrder: 0,
      createdAt: now,
      updatedAt: now,
    );
  }

  bool isToolEnabled(String name) => tools[name] == true;

  bool isToolNeedsApproval(String name) =>
      toolApprovals[name] ?? WorkspaceToolNames.defaultApprovalFor(name);

  List<String> get enabledToolNames => [
    for (final t in WorkspaceToolNames.allTools)
      if (isToolEnabled(t)) t,
  ];

  DependencyInstallPref prefFor(String depId) =>
      dependencyPrefs[depId] ?? const DependencyInstallPref();

  Workspace copyWith({
    String? id,
    String? displayName,
    String? alias,
    int? sortOrder,
    Map<String, bool>? tools,
    Map<String, bool>? toolApprovals,
    bool? shellEnabled,
    String? customHostPath,
    bool? readOnly,
    Map<String, DependencyInstallPref>? dependencyPrefs,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool clearCustomHostPath = false,
  }) {
    return Workspace(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      alias: alias ?? this.alias,
      sortOrder: sortOrder ?? this.sortOrder,
      tools: tools ?? this.tools,
      toolApprovals: toolApprovals ?? this.toolApprovals,
      shellEnabled: shellEnabled ?? this.shellEnabled,
      customHostPath: clearCustomHostPath
          ? null
          : (customHostPath ?? this.customHostPath),
      readOnly: readOnly ?? this.readOnly,
      dependencyPrefs: dependencyPrefs ?? this.dependencyPrefs,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'alias': alias,
    'sortOrder': sortOrder,
    'tools': tools,
    'toolApprovals': toolApprovals,
    'shellEnabled': shellEnabled,
    if (customHostPath != null) 'customHostPath': customHostPath,
    'readOnly': readOnly,
    'dependencyPrefs': {
      for (final e in dependencyPrefs.entries) e.key: e.value.toJson(),
    },
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory Workspace.fromJson(Map<String, dynamic> json) {
    final toolsRaw = json['tools'];
    final tools = <String, bool>{
      for (final t in WorkspaceToolNames.filesystemTools)
        t: WorkspaceToolNames.defaultEnabled.contains(t),
      WorkspaceToolNames.shell: false,
    };
    if (toolsRaw is Map) {
      for (final e in toolsRaw.entries) {
        final k = e.key.toString();
        if (WorkspaceToolNames.isWorkspaceTool(k)) {
          tools[k] = e.value == true;
        }
      }
    }
    // Legacy kelivo_* keys from intermediate dumps.
    const legacyMap = <String, String>{
      'kelivo_read': WorkspaceToolNames.read,
      'kelivo_write_file': WorkspaceToolNames.write,
      'kelivo_patch_file': WorkspaceToolNames.patch,
      'kelivo_delete': WorkspaceToolNames.delete,
      'kelivo_glob': WorkspaceToolNames.glob,
      'kelivo_grep': WorkspaceToolNames.grep,
      'kelivo_outline': WorkspaceToolNames.outline,
      'kelivo_mkdir': WorkspaceToolNames.mkdir,
      'kelivo_move': WorkspaceToolNames.move,
      'kelivo_zip': WorkspaceToolNames.zip,
      'kelivo_unzip': WorkspaceToolNames.unzip,
      'kelivo_shell': WorkspaceToolNames.shell,
    };
    if (toolsRaw is Map) {
      for (final e in toolsRaw.entries) {
        final mapped = legacyMap[e.key.toString()];
        if (mapped != null) tools[mapped] = e.value == true;
      }
    }

    final prefsRaw = json['dependencyPrefs'];
    final prefs = <String, DependencyInstallPref>{};
    if (prefsRaw is Map) {
      for (final e in prefsRaw.entries) {
        if (e.value is Map) {
          prefs[e.key.toString()] = DependencyInstallPref.fromJson(
            (e.value as Map).cast<String, dynamic>(),
          );
        }
      }
    }

    final approvalsRaw = json['toolApprovals'];
    final approvals = <String, bool>{
      for (final t in WorkspaceToolNames.allTools)
        t: WorkspaceToolNames.defaultApprovalFor(t),
    };
    if (approvalsRaw is Map) {
      for (final e in approvalsRaw.entries) {
        final k = e.key.toString();
        if (WorkspaceToolNames.isWorkspaceTool(k)) {
          approvals[k] = e.value == true;
        }
      }
    }

    return Workspace(
      id: (json['id'] as String?)?.trim().isNotEmpty == true
          ? (json['id'] as String).trim()
          : defaultId,
      displayName: (json['displayName'] as String?)?.trim().isNotEmpty == true
          ? (json['displayName'] as String).trim()
          : 'Default',
      alias: (json['alias'] as String?)?.trim().isNotEmpty == true
          ? (json['alias'] as String).trim()
          : defaultAlias,
      sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
      tools: tools,
      toolApprovals: approvals,
      shellEnabled: json['shellEnabled'] as bool? ?? false,
      customHostPath:
          (json['customHostPath'] as String?)?.trim().isNotEmpty == true
          ? (json['customHostPath'] as String).trim()
          : null,
      readOnly: json['readOnly'] as bool? ?? false,
      dependencyPrefs: prefs,
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.now(),
    );
  }

  static String encodeList(List<Workspace> list) =>
      jsonEncode(list.map((e) => e.toJson()).toList());

  static List<Workspace> decodeList(String raw) {
    try {
      final arr = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in arr)
          if (e is Map) Workspace.fromJson(e.cast<String, dynamic>()),
      ];
    } catch (_) {
      return const <Workspace>[];
    }
  }
}
