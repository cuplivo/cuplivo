import 'package:flutter/foundation.dart';

/// One remote DeepSeek Harness this device knows how to reach.
///
/// This is a *connection record*, not an assistant: it carries no model, no
/// prompt, no memory and no conversation. DeepSeek Harness keeps every session
/// and every setting on its own host, so a record holds only what this device
/// needs to find that host again:
///
/// - [baseUrl] — the server origin without the launch token query
///   (`http://192.168.1.20:3080`);
/// - [authority] — `host[:port]` in the form the server binds its session
///   cookie to (the cookie is never stored beside this record, see
///   `DshCredentialStore`);
/// - [secure] — whether the origin is `https`, which decides whether the cookie
///   is `Secure`;
/// - the timestamps the owner list and the connection settings show, plus the
///   last failure code so a dead link is visible after a restart.
///
/// The launch token from the pasted WebUI link is deliberately absent: it is
/// used once for the login request and held in memory for that attempt only.
/// Everything the server owns stays on the server.
@immutable
class DshRemote {
  const DshRemote({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.authority,
    required this.secure,
    required this.createdAt,
    this.lastConnectedAt,
    this.lastError,
  });

  /// Stable id, also the `ChatOwner` id and the secure-storage suffix.
  final String id;

  /// Display name, user-editable. Defaults to the product name in the UI when
  /// empty; the model itself carries no user-visible text.
  final String name;

  /// Server origin, e.g. `http://192.168.1.20:3080`; never carries a query.
  final String baseUrl;

  /// `host[:port]`, used for diagnostics and as the cookie's authority.
  final String authority;

  /// Whether [baseUrl] is `https`.
  final bool secure;

  final DateTime createdAt;
  final DateTime? lastConnectedAt;

  /// The [DshFailure] name of the last failed connect, or null when the last
  /// attempt succeeded or none ran. The UI maps it to a localized sentence;
  /// technical detail is not persisted.
  final String? lastError;

  Uri get uri => Uri.parse(baseUrl);

  DshRemote copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? authority,
    bool? secure,
    DateTime? createdAt,
    Object? lastConnectedAt = _unset,
    Object? lastError = _unset,
  }) {
    return DshRemote(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      authority: authority ?? this.authority,
      secure: secure ?? this.secure,
      createdAt: createdAt ?? this.createdAt,
      lastConnectedAt: identical(lastConnectedAt, _unset)
          ? this.lastConnectedAt
          : lastConnectedAt as DateTime?,
      lastError: identical(lastError, _unset)
          ? this.lastError
          : lastError as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'authority': authority,
    'secure': secure,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (lastConnectedAt != null)
      'lastConnectedAt': lastConnectedAt!.toUtc().toIso8601String(),
    if (lastError != null) 'lastError': lastError,
  };

  /// Tolerant of missing/garbage fields, like every persisted model here: a
  /// blob written by an older build must not make the whole list unreadable.
  /// A record without an id is dropped by `DshRemoteStore` rather than
  /// trusted.
  factory DshRemote.fromJson(Map<String, dynamic> json) {
    final rawCreated = json['createdAt'];
    return DshRemote(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      baseUrl: (json['baseUrl'] ?? '').toString(),
      authority: (json['authority'] ?? '').toString(),
      secure: json['secure'] == true,
      createdAt:
          DateTime.tryParse(rawCreated?.toString() ?? '')?.toLocal() ??
          DateTime.now(),
      lastConnectedAt: DateTime.tryParse(
        (json['lastConnectedAt'] ?? '').toString(),
      )?.toLocal(),
      lastError: (json['lastError'] as Object?)?.toString(),
    );
  }

  static const Object _unset = Object();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshRemote &&
          other.id == id &&
          other.name == name &&
          other.baseUrl == baseUrl &&
          other.authority == authority &&
          other.secure == secure &&
          other.createdAt.microsecondsSinceEpoch ==
              createdAt.microsecondsSinceEpoch &&
          other.lastConnectedAt?.microsecondsSinceEpoch ==
              lastConnectedAt?.microsecondsSinceEpoch &&
          other.lastError == lastError;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    baseUrl,
    authority,
    secure,
    createdAt.microsecondsSinceEpoch,
    lastConnectedAt?.microsecondsSinceEpoch,
    lastError,
  );

  @override
  String toString() => 'DshRemote($id, $name, $baseUrl)';
}
