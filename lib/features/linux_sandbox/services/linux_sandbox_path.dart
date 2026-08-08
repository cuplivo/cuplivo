import 'dart:io';

import 'package:path/path.dart' as p;

class LinuxSandboxPathException implements Exception {
  final String code;
  final String message;

  const LinuxSandboxPathException(this.code, this.message);

  @override
  String toString() => message;
}

/// Path jail helpers for Linux Sandbox local roots.
///
/// Threat model: guest paths must resolve inside [jailRoot] after normalize
/// and (when possible) symlink canonicalization. Reject `..`, absolute host
/// paths as guest input, empty/unsafe Win32 segments, and symlink targets
/// that leave the jail.
class LinuxSandboxPath {
  const LinuxSandboxPath._();

  static String normalizeRoot(String jailRoot) {
    final normalized = p.normalize(jailRoot.trim());
    if (normalized.isEmpty) {
      throw const LinuxSandboxPathException(
        'invalid_root',
        'Jail root is empty',
      );
    }
    return normalized;
  }

  /// Whether [candidate] is strictly inside or equal to [root] after normalize.
  static bool isUnderRoot(String root, String candidate) {
    final r = p.normalize(root);
    final c = p.normalize(candidate);
    if (p.equals(r, c)) return true;
    return p.isWithin(r, c);
  }

  /// Validate and split a guest path into relative segments (forward or back
  /// slash). Does not touch the filesystem.
  static List<String> guestSegments(String guestPath) {
    if (guestPath.trim() != guestPath) {
      throw LinuxSandboxPathException(
        'unsafe_segment',
        'Leading/trailing whitespace is not allowed: $guestPath',
      );
    }
    if (guestPath.isEmpty ||
        guestPath == '.' ||
        guestPath == '/' ||
        guestPath == '\\') {
      return const <String>[];
    }

    if (_looksAbsoluteHostPath(guestPath)) {
      throw LinuxSandboxPathException(
        'absolute_path',
        'Absolute host paths are not allowed: $guestPath',
      );
    }

    final unified = guestPath.replaceAll('\\', '/');
    final rawParts = unified.split('/');
    final segments = <String>[];
    for (final part in rawParts) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        throw LinuxSandboxPathException(
          'path_escape',
          'Path escape rejected: $guestPath',
        );
      }
      if (!_isSafeSegment(part)) {
        throw LinuxSandboxPathException(
          'unsafe_segment',
          'Unsafe path segment rejected: $guestPath',
        );
      }
      segments.add(part);
    }
    return segments;
  }

  /// Join guest path under [jailRoot] without symlink resolution.
  static String joinGuest(String jailRoot, String guestPath) {
    final root = normalizeRoot(jailRoot);
    final segments = guestSegments(guestPath);
    if (segments.isEmpty) return root;
    return p.normalize(p.joinAll([root, ...segments]));
  }

  /// Resolve guest path under jail: normalize, optional symlink canonicalize,
  /// reject if final path is outside the jail root.
  static Future<String> resolveHostPath({
    required String jailRoot,
    required String guestPath,
    bool resolveSymlinks = true,
  }) async {
    final rootNorm = normalizeRoot(jailRoot);
    final joined = joinGuest(rootNorm, guestPath);

    String rootCanon = rootNorm;
    String targetCanon = joined;

    if (resolveSymlinks) {
      rootCanon = await _tryCanonicalize(rootNorm);
      targetCanon = await _tryCanonicalize(joined);
    } else {
      rootCanon = p.normalize(rootNorm);
      targetCanon = p.normalize(joined);
    }

    if (!isUnderRoot(rootCanon, targetCanon)) {
      throw LinuxSandboxPathException(
        'path_escape',
        'Resolved path escapes jail: $guestPath',
      );
    }
    return targetCanon;
  }

  static bool _looksAbsoluteHostPath(String s) {
    if (s.startsWith('/') || s.startsWith('\\')) return true;
    if (s.startsWith('\\\\')) return true;
    if (s.length >= 3) {
      final c0 = s.codeUnitAt(0);
      final isLetter = (c0 >= 0x41 && c0 <= 0x5a) || (c0 >= 0x61 && c0 <= 0x7a);
      if (isLetter && s[1] == ':' && (s[2] == '/' || s[2] == '\\')) {
        return true;
      }
    }
    return false;
  }

  /// Win32-aware segment safety (aligned with filesystem wire segments).
  static bool _isSafeSegment(String seg) {
    if (seg.isEmpty) return false;
    if (seg.contains('\u0000') || seg.contains(':')) return false;
    if (seg.endsWith(' ') || seg.endsWith('.')) return false;
    if (RegExp(r'^\.+$').hasMatch(seg)) return false;
    return true;
  }

  static Future<String> _tryCanonicalize(String path) async {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      // Canonicalize existing parent prefix; append missing tail.
      final parts = p.split(p.normalize(path));
      if (parts.isEmpty) return p.normalize(path);
      var existing = parts.first;
      var idx = 1;
      // Drive / UNC root handling on Windows: first component may be `C:`
      if (Platform.isWindows && parts.isNotEmpty) {
        existing = parts[0];
        idx = 1;
        if (parts.length > 1 &&
            (parts[0].endsWith(':') || parts[0].startsWith(r'\\'))) {
          existing = p.join(parts[0], parts[1]);
          idx = 2;
        }
      }
      var built = existing;
      while (idx < parts.length) {
        final next = p.join(built, parts[idx]);
        final t = FileSystemEntity.typeSync(next, followLinks: false);
        if (t == FileSystemEntityType.notFound) break;
        built = next;
        idx++;
      }
      String canonExisting;
      try {
        canonExisting = await Directory(built).resolveSymbolicLinks();
      } catch (_) {
        try {
          canonExisting = await File(built).resolveSymbolicLinks();
        } catch (_) {
          canonExisting = p.normalize(built);
        }
      }
      if (idx >= parts.length) return p.normalize(canonExisting);
      return p.normalize(p.joinAll([canonExisting, ...parts.sublist(idx)]));
    }
    try {
      if (type == FileSystemEntityType.directory) {
        return p.normalize(await Directory(path).resolveSymbolicLinks());
      }
      return p.normalize(await File(path).resolveSymbolicLinks());
    } catch (_) {
      return p.normalize(path);
    }
  }
}
