enum LinuxSandboxStatus { disabled, notReady, installing, ready, broken }

enum LinuxSandboxRuntimeMode {
  unknown,
  unsupported,
  localJail,
  wsl,
  nativeLinux,
  proot,
}

class LinuxSandboxToolNames {
  const LinuxSandboxToolNames._();

  static const String read = 'linux_sandbox_read';
  static const String write = 'linux_sandbox_write';
  static const String edit = 'linux_sandbox_edit';
  static const String shell = 'linux_sandbox_shell';

  static const List<String> all = [read, write, edit, shell];
}

class LinuxSandboxToolConfig {
  final bool enabled;
  final bool needsApproval;

  const LinuxSandboxToolConfig({
    this.enabled = true,
    this.needsApproval = true,
  });

  LinuxSandboxToolConfig copyWith({bool? enabled, bool? needsApproval}) {
    return LinuxSandboxToolConfig(
      enabled: enabled ?? this.enabled,
      needsApproval: needsApproval ?? this.needsApproval,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'needsApproval': needsApproval,
  };

  static LinuxSandboxToolConfig fromJson(Map<String, dynamic> json) {
    return LinuxSandboxToolConfig(
      enabled: _readBool(json['enabled'], fallback: true),
      needsApproval: _readBool(json['needsApproval'], fallback: true),
    );
  }
}

class LinuxSandbox {
  static const String baseEnvPackId = 'baseEnv';

  final String id;
  final String name;
  final String? description;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, LinuxSandboxToolConfig> tools;
  final List<String> enabledEnvPacks;
  final LinuxSandboxStatus status;
  final LinuxSandboxRuntimeMode runtimeMode;
  final String? statusMessage;
  final String? lastInstallError;

  LinuxSandbox({
    required this.id,
    required this.name,
    this.description,
    DateTime? createdAt,
    DateTime? updatedAt,
    Map<String, LinuxSandboxToolConfig>? tools,
    List<String>? enabledEnvPacks,
    this.status = LinuxSandboxStatus.notReady,
    this.runtimeMode = LinuxSandboxRuntimeMode.unknown,
    this.statusMessage,
    this.lastInstallError,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now(),
       tools = Map<String, LinuxSandboxToolConfig>.from(
         tools ?? defaultTools(),
       ),
       enabledEnvPacks = List<String>.from(enabledEnvPacks ?? const <String>[]);

  static Map<String, LinuxSandboxToolConfig> defaultTools() {
    return {
      LinuxSandboxToolNames.read: const LinuxSandboxToolConfig(
        enabled: true,
        needsApproval: false,
      ),
      LinuxSandboxToolNames.write: const LinuxSandboxToolConfig(
        enabled: true,
        needsApproval: true,
      ),
      LinuxSandboxToolNames.edit: const LinuxSandboxToolConfig(
        enabled: true,
        needsApproval: true,
      ),
      LinuxSandboxToolNames.shell: const LinuxSandboxToolConfig(
        enabled: true,
        needsApproval: true,
      ),
    };
  }

  LinuxSandbox copyWith({
    String? id,
    String? name,
    String? description,
    bool clearDescription = false,
    DateTime? createdAt,
    DateTime? updatedAt,
    Map<String, LinuxSandboxToolConfig>? tools,
    List<String>? enabledEnvPacks,
    LinuxSandboxStatus? status,
    LinuxSandboxRuntimeMode? runtimeMode,
    String? statusMessage,
    bool clearStatusMessage = false,
    String? lastInstallError,
    bool clearLastInstallError = false,
  }) {
    return LinuxSandbox(
      id: id ?? this.id,
      name: name ?? this.name,
      description: clearDescription ? null : (description ?? this.description),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      tools: tools ?? this.tools,
      enabledEnvPacks: enabledEnvPacks ?? this.enabledEnvPacks,
      status: status ?? this.status,
      runtimeMode: runtimeMode ?? this.runtimeMode,
      statusMessage: clearStatusMessage
          ? null
          : (statusMessage ?? this.statusMessage),
      lastInstallError: clearLastInstallError
          ? null
          : (lastInstallError ?? this.lastInstallError),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'tools': tools.map((k, v) => MapEntry(k, v.toJson())),
    'enabledEnvPacks': enabledEnvPacks,
    'status': status.name,
    'runtimeMode': runtimeMode.name,
    'statusMessage': statusMessage,
    'lastInstallError': lastInstallError,
  };

  static LinuxSandbox fromJson(Map<String, dynamic> json) {
    final toolsRaw = json['tools'];
    final tools = Map<String, LinuxSandboxToolConfig>.from(defaultTools());
    if (toolsRaw is Map) {
      for (final entry in toolsRaw.entries) {
        final key = entry.key.toString();
        if (!LinuxSandboxToolNames.all.contains(key)) continue;
        final value = entry.value;
        if (value is Map) {
          tools[key] = LinuxSandboxToolConfig.fromJson(
            value.cast<String, dynamic>(),
          );
        }
      }
    }
    final packsRaw = json['enabledEnvPacks'];
    final packs = <String>[];
    if (packsRaw is List) {
      for (final item in packsRaw) {
        if (item == null) continue;
        final s = item.toString();
        if (s.isNotEmpty) packs.add(s);
      }
    }
    return LinuxSandbox(
      id: _readString(json['id']) ?? '',
      name: _readString(json['name']) ?? '',
      description: _readString(json['description']),
      createdAt: _readDateTime(json['createdAt']) ?? DateTime.now(),
      updatedAt: _readDateTime(json['updatedAt']) ?? DateTime.now(),
      tools: tools,
      enabledEnvPacks: packs,
      status: _parseStatus(json['status']),
      runtimeMode: _parseRuntimeMode(json['runtimeMode']),
      statusMessage: _readString(json['statusMessage']),
      lastInstallError: _readString(json['lastInstallError']),
    );
  }
}

/// Missing status key (v1 metadata) → ready so existing sandboxes keep working.
/// Empty or unknown status string → broken (never silent-ready).
LinuxSandboxStatus _parseStatus(Object? value) {
  if (value == null) return LinuxSandboxStatus.ready;
  final s = value.toString().trim();
  if (s.isEmpty) return LinuxSandboxStatus.broken;
  for (final e in LinuxSandboxStatus.values) {
    if (e.name == s) return e;
  }
  return LinuxSandboxStatus.broken;
}

LinuxSandboxRuntimeMode _parseRuntimeMode(Object? value) {
  if (value == null) return LinuxSandboxRuntimeMode.unknown;
  final s = value.toString().trim();
  if (s.isEmpty) return LinuxSandboxRuntimeMode.unknown;
  for (final e in LinuxSandboxRuntimeMode.values) {
    if (e.name == s) return e;
  }
  return LinuxSandboxRuntimeMode.unknown;
}

bool _readBool(Object? value, {required bool fallback}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final lower = value.toLowerCase().trim();
    if (lower == 'true' || lower == '1') return true;
    if (lower == 'false' || lower == '0') return false;
  }
  return fallback;
}

String? _readString(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  return value.toString();
}

DateTime? _readDateTime(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}
