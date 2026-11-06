/// The backup archive's format numbers, in one place.
///
/// Two files used to restate them: `DataSync` validates a source archive it is
/// about to restore, and `RestoreBundleStaging` writes and re-reads the staged
/// candidate. They describe the same format, so a bump that touched only one of
/// them would leave this build rejecting archives it had just written — the
/// kind of split the schema-version comments in
/// `SchemaMigrations` warn about, one level down.
final class BackupArchiveFormat {
  BackupArchiveFormat._();

  /// The format this build writes, and the one its staged candidate carries.
  static const current = 4;

  /// The oldest format a written archive declares it can be read by. Written
  /// into every manifest as `minimumReadableFormatVersion`; see
  /// `SchemaMigrations.minimumReadableSchemaVersion` for the database axis.
  static const minimumReadable = 4;

  /// Formats this build still restores although it no longer writes them.
  ///
  /// `2` is v1.3.0's. `3` is the format a Kelivo-targeted export is written in,
  /// so refusing it would make a backup this build produced for a Kelivo user
  /// unreadable to the build that produced it.
  static const legacyReadable = <int>{2, 3};
}
