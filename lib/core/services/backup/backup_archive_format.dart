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

  /// The last format whose manifest carries no `scope` block to validate.
  static const scopeLess = 2;

  /// Formats whose manifest carries a full `scope` block, so a missing or
  /// partial one is a refusal.
  ///
  /// Derived, never restated: the check that reads this used to be spelled
  /// "equals the format this build writes", which covered format 3 only while 3
  /// *was* current and silently stopped covering it — the format of every
  /// backup written before the bump — the day [current] became 4. An absent
  /// block then reads as *everything included*, which restores categories no
  /// archive claimed to hold.
  static final Set<int> declaresScope = {
    ...legacyReadable,
    current,
  }.difference({scopeLess});
}
