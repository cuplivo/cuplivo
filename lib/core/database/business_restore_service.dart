import '../models/backup_scope.dart';
import 'backup_content_filter.dart';
import 'backup_portability.dart';
import 'business_data.dart';
import 'business_repository.dart';
import 'business_settings_merger.dart';
import 'business_settings_router.dart';

final class BusinessRestoreService {
  BusinessRestoreService(this._repository);

  final BusinessRepository _repository;

  /// The kinds whose carrier moved from the snapshot database to
  /// `settings.json` in this release.
  ///
  /// An archive written before the promotion carries every template and recipe
  /// in its database half and names neither key in its settings half, so an
  /// overwrite must not read that silence as an empty library. Every other kind
  /// keeps the overwrite rule — the settings half is the statement, and a kind
  /// it does not name is replaced; memory entries in particular are derived
  /// state that must not outlive the history the archive replaced.
  static const _libraryKinds = {
    BusinessEntityKind.compressionTemplate,
    BusinessEntityKind.compressionRecipe,
  };

  Future<Map<String, Object>> exportSettings() async =>
      BusinessSettingsRouter.exportSnapshot(
        BackupPortability.portable(await _repository.readSnapshot()),
      );

  Future<void> overwrite(
    Map<String, Object?> imported, {
    BackupScope scope = const BackupScope(),
    bool preserveExplicitEmptyInstructionList = false,
    Map<String, Object?>? entityRowIds,
    bool assumePreV3EmbeddingMigrationWhenVersionMissing = false,
  }) async {
    final selected = BackupContentFilter.select(
      _portablePreferences(imported),
      scope,
    );
    // A key the archive names is the archive's answer for that kind, empty list
    // included. Naming neither library key means the archive predates the
    // promotion, so the rows already present are its only copy.
    final keepLocal = {
      for (final kind in _libraryKinds)
        if (!selected.containsKey(kind.sourceKey)) kind,
    };
    final replacement = BackupPortability.portable(
      BusinessSettingsRouter.normalizeAndRoute(
        selected,
        preserveExplicitEmptyInstructionList:
            preserveExplicitEmptyInstructionList,
        entityRowIds: entityRowIds == null
            ? null
            : BackupContentFilter.select(entityRowIds, scope),
        assumePreV3EmbeddingMigrationWhenVersionMissing:
            assumePreV3EmbeddingMigrationWhenVersionMissing,
      ),
    );
    await _repository.transformSnapshot(
      (current) => BackupPortability.preserveDeviceState(
        BackupContentFilter.preserveUnselected(
          replacement,
          current,
          scope,
          keepLocal: keepLocal,
        ),
        current,
      ),
      writeReceipt: true,
    );
  }

  Future<void> merge(
    Map<String, Object?> imported, {
    BackupScope scope = const BackupScope(),
    bool preserveExplicitEmptyInstructionList = false,
    Map<String, Object?>? entityRowIds,
    bool assumePreV3EmbeddingMigrationWhenVersionMissing = false,
  }) async {
    // Validate and normalize before opening the write transaction. The
    // transaction then merges those immutable imported rows with its current
    // snapshot, preserving both sides' database identities.
    final incoming = BackupPortability.portable(
      BusinessSettingsRouter.normalizeAndRoute(
        BackupContentFilter.select(_portablePreferences(imported), scope),
        preserveExplicitEmptyInstructionList:
            preserveExplicitEmptyInstructionList,
        entityRowIds: entityRowIds == null
            ? null
            : BackupContentFilter.select(entityRowIds, scope),
        assumePreV3EmbeddingMigrationWhenVersionMissing:
            assumePreV3EmbeddingMigrationWhenVersionMissing,
      ),
    );
    await _repository.transformSnapshot((current) {
      return BusinessSettingsMerger.mergeSnapshots(
        current,
        incoming,
        incomingKeys: BackupContentFilter.select(imported, scope).keys.toSet(),
      );
    }, writeReceipt: true);
  }

  static Map<String, Object?> _portablePreferences(
    Map<String, Object?> values,
  ) => {...values}
    ..removeWhere(
      (key, _) => BackupPortability.devicePreferenceKeys.contains(key),
    );
}
