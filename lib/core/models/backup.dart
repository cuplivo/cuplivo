import 'dart:convert';

enum RestoreMode {
  overwrite, // 完全覆盖：清空本地后恢复
  merge, // 增量合并：智能去重
}

/// What a backup ZIP includes, at 6 pre-defined sections.
///
/// Replaces the old `includeChats`/`includeFiles` pair (single source of
/// truth for full backups, incremental backups, LAN sync and the restore
/// gate). `fromJson` accepts the legacy pair so old config JSON lands on the
/// equivalent bits; `toJson` keeps writing the legacy keys so old builds
/// reading a new config still see their two toggles.
class BackupContentScope {
  /// 聊天记录及助手: conversations/messages JSONL + assistants/memories keys
  /// split out of settings.json.
  final bool chatsAndAssistants;

  /// 设置项: settings.json minus the assistant keys.
  final bool settings;

  /// 附件: `upload/` (message attachments) + `images/` (generated images).
  final bool attachments;

  /// 工作区: `workspaces/` user sandbox.
  final bool workspaces;

  /// 技能: `skills/`. No longer "always packed" — follows this bit.
  final bool skills;

  /// 字体与头像: `fonts/` + `avatars/`.
  final bool fontsAndAvatars;

  const BackupContentScope({
    this.chatsAndAssistants = true,
    this.settings = true,
    this.attachments = true,
    this.workspaces = true,
    this.skills = true,
    this.fontsAndAvatars = true,
  });

  BackupContentScope copyWith({
    bool? chatsAndAssistants,
    bool? settings,
    bool? attachments,
    bool? workspaces,
    bool? skills,
    bool? fontsAndAvatars,
  }) {
    return BackupContentScope(
      chatsAndAssistants: chatsAndAssistants ?? this.chatsAndAssistants,
      settings: settings ?? this.settings,
      attachments: attachments ?? this.attachments,
      workspaces: workspaces ?? this.workspaces,
      skills: skills ?? this.skills,
      fontsAndAvatars: fontsAndAvatars ?? this.fontsAndAvatars,
    );
  }

  /// Settings content is requested by either of the two settings-y bits.
  bool get anySettings => settings || chatsAndAssistants;

  /// Any file tree bit set (drives the legacy `includeFiles` getter).
  bool get anyFiles => attachments || workspaces || skills || fontsAndAvatars;

  Map<String, dynamic> toJson() => {
    'chatsAndAssistants': chatsAndAssistants,
    'settings': settings,
    'attachments': attachments,
    'workspaces': workspaces,
    'skills': skills,
    'fontsAndAvatars': fontsAndAvatars,
  };

  /// Reads the scope JSON, falling back to the legacy two-toggle semantics
  /// when the new object is absent (old configs). Legacy mapping:
  ///  - `includeChats` → chats bit (settings.json was always exported and
  ///    always carried assistants, so the assistant keys now ride chats)
  ///  - `includeFiles` → attachments + workspaces + fontsAndAvatars
  ///  - skills stay true (old ZIPs always packed them)
  static BackupContentScope fromJson(
    Map<String, dynamic> json, {
    bool? legacyIncludeChats,
    bool? legacyIncludeFiles,
  }) {
    if (json.containsKey('chatsAndAssistants')) {
      return BackupContentScope(
        chatsAndAssistants: json['chatsAndAssistants'] as bool? ?? true,
        settings: json['settings'] as bool? ?? true,
        attachments: json['attachments'] as bool? ?? true,
        workspaces: json['workspaces'] as bool? ?? true,
        skills: json['skills'] as bool? ?? true,
        fontsAndAvatars: json['fontsAndAvatars'] as bool? ?? true,
      );
    }
    final legacyChats = legacyIncludeChats ?? true;
    final legacyFiles = legacyIncludeFiles ?? true;
    return BackupContentScope(
      chatsAndAssistants: legacyChats,
      settings: true,
      attachments: legacyFiles,
      workspaces: legacyFiles,
      skills: true,
      fontsAndAvatars: legacyFiles,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BackupContentScope &&
      other.chatsAndAssistants == chatsAndAssistants &&
      other.settings == settings &&
      other.attachments == attachments &&
      other.workspaces == workspaces &&
      other.skills == skills &&
      other.fontsAndAvatars == fontsAndAvatars;

  @override
  int get hashCode => Object.hash(
    chatsAndAssistants,
    settings,
    attachments,
    workspaces,
    skills,
    fontsAndAvatars,
  );
}

class WebDavConfig {
  final String url;
  final String username;
  final String password;
  final String path;
  final String userAgent;

  /// What a backup through this channel includes (both full and incremental).
  final BackupContentScope content;

  const WebDavConfig({
    this.url = '',
    this.username = '',
    this.password = '',
    this.path = 'kelivo_backups',
    this.userAgent = '',
    this.content = const BackupContentScope(),
  });

  /// Legacy aliases — semantics of the old two toggles (skills excluded from
  /// files, exactly like the pre-scope packer).
  bool get includeChats => content.chatsAndAssistants;
  bool get includeFiles =>
      content.attachments || content.workspaces || content.fontsAndAvatars;

  WebDavConfig copyWith({
    String? url,
    String? username,
    String? password,
    String? path,
    String? userAgent,
    BackupContentScope? content,
  }) {
    return WebDavConfig(
      url: url ?? this.url,
      username: username ?? this.username,
      password: password ?? this.password,
      path: path ?? this.path,
      userAgent: userAgent ?? this.userAgent,
      content: content ?? this.content,
    );
  }

  /// Derived channel enabled state (issue #306): a WebDAV channel is
  /// usable when the server URL is filled in. Username/password are optional
  /// (public servers need no auth).
  bool get isConfigured => url.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
    'url': url,
    'username': username,
    'password': password,
    'path': path,
    'userAgent': userAgent,
    'content': content.toJson(),
    // Legacy keys: old builds keep reading their two toggles.
    'includeChats': content.chatsAndAssistants,
    'includeFiles':
        content.attachments || content.workspaces || content.fontsAndAvatars,
  };

  static WebDavConfig fromJson(Map<String, dynamic> json) {
    return WebDavConfig(
      url: (json['url'] as String?)?.trim() ?? '',
      username: (json['username'] as String?)?.trim() ?? '',
      password: (json['password'] as String?) ?? '',
      path: (json['path'] as String?)?.trim().isNotEmpty == true
          ? (json['path'] as String).trim()
          : 'kelivo_backups',
      userAgent: (json['userAgent'] as String?) ?? '',
      content: BackupContentScope.fromJson(
        (json['content'] as Map?)?.cast<String, dynamic>() ?? const {},
        legacyIncludeChats: json['includeChats'] as bool?,
        legacyIncludeFiles: json['includeFiles'] as bool?,
      ),
    );
  }

  static WebDavConfig fromJsonString(String s) {
    try {
      final map = jsonDecode(s) as Map<String, dynamic>;
      return WebDavConfig.fromJson(map);
    } catch (_) {
      return const WebDavConfig();
    }
  }

  String toJsonString() => jsonEncode(toJson());
}

class S3Config {
  final String
  endpoint; // e.g. https://s3.amazonaws.com or https://<accountid>.r2.cloudflarestorage.com
  final String
  region; // e.g. us-east-1 / auto (for some S3-compatible providers)
  final String bucket;
  final String accessKeyId;
  final String secretAccessKey;
  final String sessionToken; // optional
  final String prefix; // object key prefix/folder
  final bool
  pathStyle; // safer for custom endpoints (no bucket subdomain TLS mismatch)
  final String userAgent;

  /// What a backup through this channel includes (both full and incremental).
  final BackupContentScope content;

  const S3Config({
    this.endpoint = '',
    this.region = 'us-east-1',
    this.bucket = '',
    this.accessKeyId = '',
    this.secretAccessKey = '',
    this.sessionToken = '',
    this.prefix = 'kelivo_backups',
    this.pathStyle = true,
    this.userAgent = '',
    this.content = const BackupContentScope(),
  });

  /// Legacy aliases — semantics of the old two toggles (skills excluded from
  /// files, exactly like the pre-scope packer).
  bool get includeChats => content.chatsAndAssistants;
  bool get includeFiles =>
      content.attachments || content.workspaces || content.fontsAndAvatars;

  S3Config copyWith({
    String? endpoint,
    String? region,
    String? bucket,
    String? accessKeyId,
    String? secretAccessKey,
    String? sessionToken,
    String? prefix,
    bool? pathStyle,
    String? userAgent,
    BackupContentScope? content,
  }) {
    return S3Config(
      endpoint: endpoint ?? this.endpoint,
      region: region ?? this.region,
      bucket: bucket ?? this.bucket,
      accessKeyId: accessKeyId ?? this.accessKeyId,
      secretAccessKey: secretAccessKey ?? this.secretAccessKey,
      sessionToken: sessionToken ?? this.sessionToken,
      prefix: prefix ?? this.prefix,
      pathStyle: pathStyle ?? this.pathStyle,
      userAgent: userAgent ?? this.userAgent,
      content: content ?? this.content,
    );
  }

  /// Derived channel enabled state (issue #306): an S3 channel is usable
  /// when the connection essentials are filled in. Region, sessionToken and
  /// prefix have defaults, so they never gate the state.
  bool get isConfigured =>
      endpoint.trim().isNotEmpty &&
      bucket.trim().isNotEmpty &&
      accessKeyId.trim().isNotEmpty &&
      secretAccessKey.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
    'endpoint': endpoint,
    'region': region,
    'bucket': bucket,
    'accessKeyId': accessKeyId,
    'secretAccessKey': secretAccessKey,
    'sessionToken': sessionToken,
    'prefix': prefix,
    'pathStyle': pathStyle,
    'userAgent': userAgent,
    'content': content.toJson(),
    // Legacy keys: old builds keep reading their two toggles.
    'includeChats': content.chatsAndAssistants,
    'includeFiles':
        content.attachments || content.workspaces || content.fontsAndAvatars,
  };

  static S3Config fromJson(Map<String, dynamic> json) {
    return S3Config(
      endpoint: (json['endpoint'] as String?)?.trim() ?? '',
      region: (json['region'] as String?)?.trim().isNotEmpty == true
          ? (json['region'] as String).trim()
          : 'us-east-1',
      bucket: (json['bucket'] as String?)?.trim() ?? '',
      accessKeyId: (json['accessKeyId'] as String?)?.trim() ?? '',
      secretAccessKey: (json['secretAccessKey'] as String?) ?? '',
      sessionToken: (json['sessionToken'] as String?) ?? '',
      prefix: (json['prefix'] as String?)?.trim().isNotEmpty == true
          ? (json['prefix'] as String).trim()
          : 'kelivo_backups',
      pathStyle: json['pathStyle'] as bool? ?? true,
      userAgent: (json['userAgent'] as String?) ?? '',
      content: BackupContentScope.fromJson(
        (json['content'] as Map?)?.cast<String, dynamic>() ?? const {},
        legacyIncludeChats: json['includeChats'] as bool?,
        legacyIncludeFiles: json['includeFiles'] as bool?,
      ),
    );
  }

  static S3Config fromJsonString(String s) {
    try {
      final map = jsonDecode(s) as Map<String, dynamic>;
      return S3Config.fromJson(map);
    } catch (_) {
      return const S3Config();
    }
  }

  String toJsonString() => jsonEncode(toJson());
}

class BackupFileItem {
  final Uri href; // absolute
  final String displayName;
  final int size;
  final DateTime? lastModified;
  const BackupFileItem({
    required this.href,
    required this.displayName,
    required this.size,
    required this.lastModified,
  });

  static void sortByNewest(List<BackupFileItem> items) {
    items.sort((a, b) {
      if (a.lastModified != null && b.lastModified != null) {
        return b.lastModified!.compareTo(a.lastModified!);
      }
      if (a.lastModified == null && b.lastModified == null) {
        return b.displayName.compareTo(a.displayName);
      }
      return a.lastModified == null ? 1 : -1;
    });
  }
}
