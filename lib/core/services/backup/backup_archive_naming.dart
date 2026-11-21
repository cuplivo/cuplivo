import '../../models/backup_target.dart';

/// What a backup archive is called, and what this build still answers to.
///
/// The name is a claim about the reader, not a brand: an archive written for
/// Kelivo keeps the Kelivo prefix, because that is the only signal a departing
/// user has outside the app. Everything else this build writes — a snapshot, an
/// auto-backup, an export of a local copy — is always for this build and says so.
///
/// This is one rule with two halves. The writer asks [fileNameFor]; the readers
/// ask [isReadable], [isArchiveName] and [timestampFromFileName]. 4.7.0 wrote
/// [kelivoPrefix] for every target, so a reader that only matched the new prefix
/// would stop seeing archives, partials and staging debris that already exist —
/// the failures are silent, so the set is derived here and nowhere restated.
final class BackupArchiveNaming {
  const BackupArchiveNaming._();

  /// The prefix an archive for this build is written with.
  static const cuplivoPrefix = 'cuplivo_backup_';

  /// The prefix an archive for a Kelivo release is written with, and the prefix
  /// every archive written before the rename carries.
  static const kelivoPrefix = 'kelivo_backup_';

  /// Every prefix this build can read.
  static const readablePrefixes = <String>{cuplivoPrefix, kelivoPrefix};

  /// The prefix [target]'s archive is written with.
  static String prefixFor(BackupTarget target) =>
      target == BackupTarget.kelivo ? kelivoPrefix : cuplivoPrefix;

  /// The name of a new archive for [target], stamped by the caller.
  static String fileNameFor(BackupTarget target, String timestamp) =>
      '${prefixFor(target)}$timestamp.zip';

  /// Whether [name] begins with a prefix this build can read.
  static bool isReadable(String name) {
    final lower = name.toLowerCase();
    return readablePrefixes.any(lower.startsWith);
  }

  /// Whether [name] is an archive this build can read, by prefix and extension.
  ///
  /// Encrypted archives are `.kbackup`; readers that only discover `.zip`
  /// archives keep their own extension check and use [isReadable].
  static bool isArchiveName(String name) {
    final lower = name.toLowerCase();
    return (lower.endsWith('.zip') || lower.endsWith('.kbackup')) &&
        isReadable(lower);
  }

  /// The local-time stamp in [name], or null when it carries none.
  ///
  /// The writer's stamp is [DateTime.toIso8601String] with the colons replaced,
  /// so it parses back as local time. A remote listing without Last-Modified
  /// falls back to this.
  static final _timestamped = RegExp(
    '^(?:${readablePrefixes.map(RegExp.escape).join('|')})'
    r'(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}\.\d+)\.(?:zip|kbackup)$',
    // One case rule for every reader: a store that hands [isReadable] a name in
    // another case must not make this half of the rule miss it.
    caseSensitive: false,
  );

  static DateTime? timestampFromFileName(String name) {
    final match = _timestamped.firstMatch(name);
    if (match == null) return null;
    // replaceAllMapped, not replaceAll: Dart's replacement string is literal,
    // so a `$1` there never expanded and this fallback silently returned null.
    // The separator is matched case-insensitively too, so a lower-cased name
    // still normalises to the `T` DateTime.parse expects.
    final stamp = match
        .group(1)!
        .replaceAllMapped(
          RegExp(r'T(\d{2})-(\d{2})-(\d{2})', caseSensitive: false),
          (part) => 'T${part[1]}:${part[2]}:${part[3]}',
        );
    return DateTime.tryParse(stamp);
  }
}
