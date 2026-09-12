/// Guest distribution detected from a rootfs `etc/os-release`.
///
/// Android rootfs images are real directories on the host, so the file can be
/// parsed before deciding between apt (Ubuntu/Debian) and apk (Alpine). The
/// detected value is cached in a marker file next to the rootfs; the marker
/// lives under `.sandbox/`, which backups and workspace previews skip.
library;

/// Package-manager family of the guest distribution.
enum SandboxDistroFamily { ubuntu, debian, alpine }

/// A parsed `etc/os-release` identity.
class SandboxDistro {
  const SandboxDistro({required this.id, required this.family, this.version});

  /// Lower-case `ID` from os-release (e.g. `alpine`).
  final String id;

  final SandboxDistroFamily family;

  /// `VERSION_ID` when present (e.g. `3.24.1`, `24.04`), sanitized by
  /// [sanitizeVersion]; null when absent or not a plain numeric version.
  final String? version;

  static final RegExp _versionPattern = RegExp(r'^[0-9]+(\.[0-9]+)*$');

  /// Return [raw] when it is a plain dotted numeric version, else null.
  ///
  /// The detected version is interpolated into `apkMirrorSetup`'s guest shell
  /// command, and the marker file is guest-writable (it lives under the
  /// bind-mounted workspace). Dropping anything outside digits and dots keeps
  /// that command well-formed; callers fall back to a bundled default.
  static String? sanitizeVersion(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return null;
    return _versionPattern.hasMatch(value) ? value : null;
  }

  /// Parse `etc/os-release` content. Returns null for distributions without a
  /// supported package manager, and falls back to `ID_LIKE` for derivatives.
  static SandboxDistro? parseOsRelease(String content) {
    final values = <String, String>{};
    for (final rawLine in content.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final separator = line.indexOf('=');
      if (separator <= 0) continue;
      values[line.substring(0, separator).trim().toUpperCase()] = _unquote(
        line.substring(separator + 1).trim(),
      );
    }

    final id = (values['ID'] ?? '').trim().toLowerCase();
    SandboxDistroFamily? family = _familyOf(id);
    if (family == null) {
      for (final like in (values['ID_LIKE'] ?? '').toLowerCase().split(
        RegExp(r'\s+'),
      )) {
        family = _familyOf(like);
        if (family != null) break;
      }
    }
    if (family == null) return null;

    final version = (values['VERSION_ID'] ?? '').trim();
    return SandboxDistro(
      id: id.isEmpty ? family.name : id,
      family: family,
      version: sanitizeVersion(version),
    );
  }

  static SandboxDistroFamily? _familyOf(String candidate) =>
      switch (candidate) {
        'ubuntu' => SandboxDistroFamily.ubuntu,
        'debian' => SandboxDistroFamily.debian,
        'alpine' => SandboxDistroFamily.alpine,
        _ => null,
      };

  static String _unquote(String value) {
    if (value.length >= 2) {
      final first = value[0];
      final last = value[value.length - 1];
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        return value.substring(1, value.length - 1);
      }
    }
    return value;
  }

  /// Marker serialization: explicit `key=value` lines so a truncated or
  /// hand-edited marker is rejected instead of silently misread.
  String toMarker() {
    final buffer = StringBuffer()
      ..writeln('id=$id')
      ..writeln('family=${family.name}');
    if (version != null) buffer.writeln('version=$version');
    return buffer.toString();
  }

  static SandboxDistro? fromMarker(String content) {
    final values = <String, String>{};
    for (final rawLine in content.split('\n')) {
      final line = rawLine.trim();
      final separator = line.indexOf('=');
      if (separator <= 0) continue;
      values[line.substring(0, separator).trim()] = line
          .substring(separator + 1)
          .trim();
    }
    final id = values['id'];
    if (id == null || id.isEmpty) return null;
    SandboxDistroFamily? family;
    for (final candidate in SandboxDistroFamily.values) {
      if (candidate.name == values['family']) {
        family = candidate;
        break;
      }
    }
    if (family == null) return null;
    final version = values['version'];
    return SandboxDistro(
      id: id,
      family: family,
      version: sanitizeVersion(version),
    );
  }
}
