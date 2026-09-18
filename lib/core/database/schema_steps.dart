// Hand-maintained migration-step helpers and schema wrappers over the
// generated versioned schema classes (lib/core/database/schema/). Kept out
// of the generated tree so re-running `drift_dev schema steps` never fights
// hand edits.
import 'package:drift/drift.dart' as i1;
import 'package:drift/internal/versioned_schema.dart' as i0;

import 'schema/schema_v2.dart' as v2;
import 'schema/schema_v3.dart' as v3;
import 'schema/schema_v4.dart' as v4;
import 'schema/schema_v5.dart' as v5;
import 'schema/schema_v6.dart' as v6;

final class Schema2 extends i0.VersionedSchema {
  Schema2({required super.database}) : super(version: 2);
  v2.DatabaseAtV2 get _db => v2.DatabaseAtV2(database.executor);
  @override
  late final List<i1.DatabaseSchemaEntity> entities = _db.allSchemaEntities;
  v2.ConversationRows get conversationRows => _db.conversationRows;
}

final class Schema3 extends i0.VersionedSchema {
  Schema3({required super.database}) : super(version: 3);
  v3.DatabaseAtV3 get _db => v3.DatabaseAtV3(database.executor);
  @override
  late final List<i1.DatabaseSchemaEntity> entities = _db.allSchemaEntities;
  v3.ConversationRows get conversationRows => _db.conversationRows;
  v3.MessageRows get messageRows => _db.messageRows;
  v3.AssetRows get assetRows => _db.assetRows;
  v3.TombstoneRows get tombstoneRows => _db.tombstoneRows;
  v3.ExtensionEntityRows get extensionEntityRows => _db.extensionEntityRows;
  i1.Index get idxExtensionEntitiesKindOrder =>
      _db.idxExtensionEntitiesKindOrder;
}

final class Schema4 extends i0.VersionedSchema {
  Schema4({required super.database}) : super(version: 4);
  v4.DatabaseAtV4 get _db => v4.DatabaseAtV4(database.executor);
  @override
  late final List<i1.DatabaseSchemaEntity> entities = _db.allSchemaEntities;
  v4.ConversationRows get conversationRows => _db.conversationRows;
  v4.MessageRows get messageRows => _db.messageRows;
}

final class Schema5 extends i0.VersionedSchema {
  Schema5({required super.database}) : super(version: 5);
  v5.DatabaseAtV5 get _db => v5.DatabaseAtV5(database.executor);
  @override
  late final List<i1.DatabaseSchemaEntity> entities = _db.allSchemaEntities;
  v5.GroupChatRows get groupChatRows => _db.groupChatRows;
  v5.GroupChatMemberRows get groupChatMemberRows => _db.groupChatMemberRows;
  i1.Index get idxGroupChatsUpdatedAt => _db.idxGroupChatsUpdatedAt;
}

final class Schema6 extends i0.VersionedSchema {
  Schema6({required super.database}) : super(version: 6);
  v6.DatabaseAtV6 get _db => v6.DatabaseAtV6(database.executor);
  @override
  late final List<i1.DatabaseSchemaEntity> entities = _db.allSchemaEntities;
  v6.MessageRows get messageRows => _db.messageRows;
}

i0.MigrationStepWithVersion migrationSteps({
  required Future<void> Function(i1.Migrator m, Schema2 schema) from1To2,
  required Future<void> Function(i1.Migrator m, Schema3 schema) from2To3,
  required Future<void> Function(i1.Migrator m, Schema4 schema) from3To4,
  required Future<void> Function(i1.Migrator m, Schema5 schema) from4To5,
  required Future<void> Function(i1.Migrator m, Schema6 schema) from5To6,
}) {
  return (currentVersion, database) async {
    switch (currentVersion) {
      case 1:
        final schema = Schema2(database: database);
        final migrator = i1.Migrator(database, schema);
        await from1To2(migrator, schema);
        return 2;
      case 2:
        final schema = Schema3(database: database);
        final migrator = i1.Migrator(database, schema);
        await from2To3(migrator, schema);
        return 3;
      case 3:
        final schema = Schema4(database: database);
        final migrator = i1.Migrator(database, schema);
        await from3To4(migrator, schema);
        return 4;
      case 4:
        final schema = Schema5(database: database);
        final migrator = i1.Migrator(database, schema);
        await from4To5(migrator, schema);
        return 5;
      case 5:
        final schema = Schema6(database: database);
        final migrator = i1.Migrator(database, schema);
        await from5To6(migrator, schema);
        return 6;
      default:
        throw ArgumentError.value('Unknown migration from $currentVersion');
    }
  };
}

i1.OnUpgrade stepByStep({
  required Future<void> Function(i1.Migrator m, Schema2 schema) from1To2,
  required Future<void> Function(i1.Migrator m, Schema3 schema) from2To3,
  required Future<void> Function(i1.Migrator m, Schema4 schema) from3To4,
  required Future<void> Function(i1.Migrator m, Schema5 schema) from4To5,
  required Future<void> Function(i1.Migrator m, Schema6 schema) from5To6,
}) => i0.VersionedSchema.stepByStepHelper(
  step: migrationSteps(
    from1To2: from1To2,
    from2To3: from2To3,
    from3To4: from3To4,
    from4To5: from4To5,
    from5To6: from5To6,
  ),
);
