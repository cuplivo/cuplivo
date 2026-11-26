import 'dart:developer' as developer;

import 'package:shared_preferences/shared_preferences.dart';

import 'business_data.dart';
import 'business_repository.dart';
import 'business_settings_router.dart';

abstract interface class LegacyBusinessPreferences {
  Future<Map<String, Object?>> snapshot();

  Future<void> remove(String key);
}

final class SharedPreferencesLegacyBusinessPreferences
    implements LegacyBusinessPreferences {
  SharedPreferencesLegacyBusinessPreferences(this._preferences);

  final SharedPreferences _preferences;

  static Future<SharedPreferencesLegacyBusinessPreferences> open() async =>
      SharedPreferencesLegacyBusinessPreferences(
        await SharedPreferences.getInstance(),
      );

  @override
  Future<Map<String, Object?>> snapshot() async => {
    for (final key in _preferences.getKeys()) key: _preferences.get(key),
  };

  @override
  Future<void> remove(String key) async {
    if (_preferences.containsKey(key) && !await _preferences.remove(key)) {
      throw StateError('business_migration_cleanup:$key');
    }
  }
}

enum BusinessMigrationResult {
  migrated,
  freshInstall,
  alreadyComplete,
  cleanedAfterReceipt,
  deferredCleanup,
}

final class BusinessMigrationEngine {
  BusinessMigrationEngine({
    required this.repository,
    required this.legacyPreferences,
    this._checkpoint,
  });

  final BusinessRepository repository;
  final LegacyBusinessPreferences legacyPreferences;
  final Future<bool> Function()? _checkpoint;

  Future<BusinessMigrationResult> run() async {
    final legacy = await legacyPreferences.snapshot();
    final cleanupKeys = _cleanupKeys(legacy.keys);
    if (await repository.hasMigrationReceipt()) {
      if (cleanupKeys.isEmpty) {
        return BusinessMigrationResult.alreadyComplete;
      }
      if (!await _durabilityBarrierAchieved()) {
        return BusinessMigrationResult.deferredCleanup;
      }
      await _cleanup(cleanupKeys);
      return BusinessMigrationResult.cleanedAfterReceipt;
    }

    final hasBusinessData = cleanupKeys.isNotEmpty;
    BusinessSnapshot route(Map<String, Object?> source) =>
        BusinessSettingsRouter.normalizeAndRoute(
          source,
          preserveExplicitEmptyInstructionList: true,
          assumePreV3EmbeddingMigrationWhenVersionMissing: true,
        );

    late final BusinessSnapshot routed;
    try {
      routed = route(legacy);
    } on FormatException catch (error) {
      if (error.message != BusinessEntityKind.searchService.sourceKey) {
        rethrow;
      }
      routed = route(Map<String, Object?>.from(legacy)..remove(error.message));
    }
    await repository.replaceSnapshotForMigration(
      routed,
      validatePersisted: (stored) {
        _validateEntityCounts(routed, stored);
        final expected = BusinessSettingsRouter.exportSnapshot(routed);
        final actual = BusinessSettingsRouter.exportSnapshot(stored);
        if (!_deepEquals(expected, actual)) {
          throw StateError('business_migration_export_mismatch');
        }
      },
    );

    if (await _durabilityBarrierAchieved()) {
      await _cleanup(cleanupKeys);
    }
    return hasBusinessData
        ? BusinessMigrationResult.migrated
        : BusinessMigrationResult.freshInstall;
  }

  Future<bool> _durabilityBarrierAchieved() async {
    try {
      return await (_checkpoint ?? repository.checkpoint)();
    } catch (error, stackTrace) {
      developer.log(
        'Business migration durability barrier failed; '
        'deferring legacy cleanup.',
        name: 'Kelivo.business.migration',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  static Set<String> _cleanupKeys(Iterable<String> keys) => {
    // A platform preference stays where it is; everything else has been moved
    // into the business store and can go.
    for (final key in keys)
      if (!BusinessKeyRegistry.isPlatformOnly(key)) key,
  };

  Future<void> _cleanup(Set<String> keys) async {
    final ordered = keys.toList()..sort();
    for (final key in ordered) {
      await legacyPreferences.remove(key);
    }
  }

  static void _validateEntityCounts(
    BusinessSnapshot expected,
    BusinessSnapshot actual,
  ) {
    for (final kind in BusinessEntityKind.values) {
      if (expected.entityCount(kind) != actual.entityCount(kind)) {
        throw StateError('business_migration_count:${kind.sourceKey}');
      }
    }
  }
}

bool _deepEquals(Object? left, Object? right) {
  if (identical(left, right) || left == right) return true;
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_deepEquals(left[index], right[index])) return false;
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_deepEquals(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  return false;
}
