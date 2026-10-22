import 'dart:io';
import 'package:path/path.dart' as p;
import 'database_installation_gate.dart';

import '../services/recycle/recycle_service.dart';
import 'app_database.dart';
import 'business_repository.dart';
import 'chat_database_observer.dart';
import 'chat_database_repository.dart';
import 'extension_entity_store.dart';

final class ChatDatabaseLease {
  ChatDatabaseLease._(
    this.repository,
    this.businessRepository,
    this.extensionEntityStore,
    this.recycleService,
    this._gateway,
  );

  /// Compatibility alias for existing chat-only callers.
  final ChatDatabaseRepository repository;
  ChatDatabaseRepository get chatRepository => repository;
  final BusinessRepository businessRepository;
  final ExtensionEntityStore extensionEntityStore;

  /// The device-local recycle bin (ADR-0016), when the opener supplied one. One
  /// instance per open database, shared by both repositories so a staged entry
  /// and a restore agree on the same store.
  final RecycleService? recycleService;
  final ChatDatabaseGateway _gateway;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _gateway._release(repository, businessRepository);
  }
}

typedef _DatabaseRepositories = ({
  ChatDatabaseRepository chat,
  BusinessRepository business,
  ExtensionEntityStore extensionEntities,
  RecycleService? recycle,
});

final class ChatDatabaseGateway {
  ChatDatabaseGateway({ChatDatabaseObserver? observer})
    : _observer = observer ?? ChatDatabaseObserver.instance;

  static final ChatDatabaseGateway instance = ChatDatabaseGateway();

  /// Builds the recycle bin for a database this gateway opens, or null (the
  /// default) to open without one.
  ///
  /// Supplying it is deliberately the opener's decision rather than the
  /// gateway's: the gateway is what test harnesses acquire too, and a bin that
  /// writes files *after* the operation that fed it returns must not be handed
  /// to every harness that happens to delete a conversation. `main` supplies it
  /// once at startup; the bin's own tests construct the service directly.
  RecycleService Function(AppDatabase database)? recycleFactory;

  _DatabaseRepositories? _repositories;
  Future<_DatabaseRepositories>? _opening;
  Future<void>? _closing;
  String? _databasePath;
  int _leaseCount = 0;
  final ChatDatabaseObserver _observer;

  Future<ChatDatabaseLease> acquire(File databaseFile) async {
    await _closing;
    final requestedPath = databaseFile.absolute.path;
    final activePath = _databasePath;
    if (activePath != null && activePath != requestedPath) {
      throw StateError('database_gateway_path_mismatch');
    }

    var repositories = _repositories;
    if (repositories == null) {
      _databasePath = requestedPath;
      final opening = _opening ??= _open(databaseFile);
      try {
        repositories = await opening;
      } catch (_) {
        if (identical(_opening, opening)) {
          _opening = null;
          _databasePath = null;
        }
        rethrow;
      }
      if (identical(_opening, opening)) {
        _repositories = repositories;
        _opening = null;
      }
    }

    _leaseCount++;
    return ChatDatabaseLease._(
      repositories.chat,
      repositories.business,
      repositories.extensionEntities,
      repositories.recycle,
      this,
    );
  }

  Future<_DatabaseRepositories> _open(File databaseFile) async {
    return _observer.measure(ChatDatabaseOperation.gatewayOpen, () async {
      final installed =
          p.basename(databaseFile.path) == AppDatabase.databaseFileName;
      if (installed && !await databaseFile.exists()) {
        await DatabaseInstallationGate.ensureReady(
          appDataDirectory: databaseFile.parent,
        );
      }
      final database = AppDatabase.open(
        file: databaseFile,
        requireExisting: installed,
      );
      final recycle = recycleFactory?.call(database);
      final chatRepository = ChatDatabaseRepository(
        database,
        databaseFile: databaseFile,
        observer: _observer,
        recycle: recycle,
      );
      try {
        await chatRepository.ensureReady();
        await chatRepository.validateConnectionContract();
        return (
          chat: chatRepository,
          business: BusinessRepository(database, recycle: recycle),
          extensionEntities: ExtensionEntityStore(database),
          recycle: recycle,
        );
      } catch (_) {
        await chatRepository.close();
        rethrow;
      }
    });
  }

  Future<void> _release(
    ChatDatabaseRepository chatRepository,
    BusinessRepository businessRepository,
  ) async {
    final repositories = _repositories;
    if (repositories == null ||
        !identical(chatRepository, repositories.chat) ||
        !identical(businessRepository, repositories.business) ||
        _leaseCount <= 0) {
      throw StateError('database_gateway_lease');
    }
    _leaseCount--;
    if (_leaseCount != 0) return;

    _repositories = null;
    _databasePath = null;
    final closing = () async {
      await chatRepository.close();
    }();
    _closing = closing;
    try {
      await closing;
    } finally {
      if (identical(_closing, closing)) _closing = null;
    }
  }
}
